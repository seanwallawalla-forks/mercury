%-----------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et
%-----------------------------------------------------------------------------%
% Copyright (C) 2000, 2003-2005 The University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%-----------------------------------------------------------------------------%

% ml_tag_switch.m - generate switches based on primary and secondary tags,
% for the MLDS back-end.

% Author: fjh.

%-----------------------------------------------------------------------------%

:- module ml_backend__ml_tag_switch.

:- interface.

:- import_module backend_libs__switch_util.
:- import_module hlds__code_model.
:- import_module hlds__hlds_data.
:- import_module ml_backend__ml_code_util.
:- import_module ml_backend__mlds.
:- import_module parse_tree__prog_data.

:- import_module list.

    % Generate efficient indexing code for tag based switches.
    %
:- pred generate(list(extended_case)::in, prog_var::in, code_model::in,
    can_fail::in, prog_context::in, mlds__defns::out, statements::out,
    ml_gen_info::in, ml_gen_info::out) is det.

:- implementation.

:- import_module backend_libs__builtin_ops.
:- import_module check_hlds__type_util.
:- import_module hlds__hlds_goal.
:- import_module hlds__hlds_module.
:- import_module ml_backend__ml_code_gen.
:- import_module ml_backend__ml_simplify_switch.
:- import_module ml_backend__ml_switch_gen.
:- import_module ml_backend__ml_unify_gen.
:- import_module parse_tree__error_util.

:- import_module assoc_list.
:- import_module int.
:- import_module map.
:- import_module require.
:- import_module std_util.
:- import_module string.

%-----------------------------------------------------------------------------%

generate(Cases, Var, CodeModel, CanFail, Context, Decls, Statements, !Info) :-
    % Generate the rval for the primary tag.
    ml_gen_var(!.Info, Var, VarLval),
    VarRval = lval(VarLval),
    PTagRval = unop(std_unop(tag), VarRval),

    % Group the cases based on primary tag value, find out how many
    % constructors share each primary tag value, and sort the cases so that
    % the most frequently occurring primary tag values come first.

    ml_gen_info_get_module_info(!.Info, ModuleInfo),
    ml_variable_type(!.Info, Var, Type),
    switch_util__get_ptag_counts(Type, ModuleInfo, MaxPrimary, PtagCountMap),
    map__to_assoc_list(PtagCountMap, PtagCountList),
    map__init(PtagCaseMap0),
    switch_util__group_cases_by_ptag(Cases, PtagCaseMap0, PtagCaseMap),
    switch_util__order_ptags_by_count(PtagCountList, PtagCaseMap,
        PtagCaseList),

    % Generate the switch on the primary tag.
    gen_ptag_cases(PtagCaseList, Var, CanFail, CodeModel,
        PtagCountMap, Context, MLDS_Cases, !Info),
    ml_switch_generate_default(CanFail, CodeModel, Context, Default, !Info),

    % Package up the results into a switch statement.
    Range = range(0, MaxPrimary),
    SwitchStmt0 = switch(mlds__native_int_type, PTagRval, Range, MLDS_Cases,
        Default),
    MLDS_Context = mlds__make_context(Context),
    ml_simplify_switch(SwitchStmt0, MLDS_Context, SwitchStatement, !Info),
    Decls = [],
    Statements = [SwitchStatement].

:- pred gen_ptag_cases(ptag_case_list::in, prog_var::in,
    can_fail::in, code_model::in, ptag_count_map::in,
    prog_context::in, list(mlds__switch_case)::out,
    ml_gen_info::in, ml_gen_info::out) is det.

gen_ptag_cases([], _, _, _, _, _, [], !Info).
gen_ptag_cases([Case | Cases], Var, CanFail, CodeModel,
        PtagCountMap, Context, [MLDS_Case | MLDS_Cases], !Info) :-
    gen_ptag_case(Case, Var, CanFail, CodeModel,
        PtagCountMap, Context, MLDS_Case, !Info),
    gen_ptag_cases(Cases, Var, CanFail, CodeModel,
        PtagCountMap, Context, MLDS_Cases, !Info).

:- pred gen_ptag_case(pair(tag_bits, ptag_case)::in,
    prog_var::in, can_fail::in, code_model::in, ptag_count_map::in,
    prog_context::in, mlds__switch_case::out,
    ml_gen_info::in, ml_gen_info::out) is det.

gen_ptag_case(Case, Var, CanFail, CodeModel, PtagCountMap, Context, MLDS_Case,
        !Info) :-
    Case = PrimaryTag - ptag_case(SecTagLocn, GoalMap),
    map__lookup(PtagCountMap, PrimaryTag, CountInfo),
    CountInfo = SecTagLocn1 - MaxSecondary,
    require(unify(SecTagLocn, SecTagLocn1),
        "ml_tag_switch.m: secondary tag locations differ"),
    map__to_assoc_list(GoalMap, GoalList),
    ( SecTagLocn = none ->
        % There is no secondary tag, so there is no switch on it.
        (
            GoalList = [],
            unexpected(this_file, "no goal for non-shared tag")
        ;
            GoalList = [_Stag - stag_goal(_ConsId, Goal)],
            ml_gen_goal(CodeModel, Goal, Statement, !Info)
        ;
            GoalList = [_, _ | _],
            unexpected(this_file, "more than one goal for non-shared tag")
        )
    ;
        (
            CanFail = cannot_fail
        ->
            CaseCanFail = cannot_fail
        ;
            list__length(GoalList, GoalCount),
            FullGoalCount = MaxSecondary + 1,
            FullGoalCount = GoalCount
        ->
            CaseCanFail = cannot_fail
        ;
            CaseCanFail = can_fail
        ),
        (
            GoalList = [_Stag - stag_goal(_ConsId, Goal)],
            CaseCanFail = cannot_fail
        ->
            % There is only one possible matching goal,
            % so we don't need to switch on it.
            ml_gen_goal(CodeModel, Goal, Statement, !Info)
        ;
            gen_stag_switch(GoalList, PrimaryTag, SecTagLocn,
                Var, CodeModel, CaseCanFail, Context, Statement, !Info)
        )
    ),
    PrimaryTagRval = const(int_const(PrimaryTag)),
    MLDS_Case = [match_value(PrimaryTagRval)] - Statement.

:- pred gen_stag_switch(stag_goal_list::in, int::in,
    stag_loc::in, prog_var::in, code_model::in, can_fail::in,
    prog_context::in, statement::out,
    ml_gen_info::in, ml_gen_info::out) is det.

gen_stag_switch(Cases, PrimaryTag, StagLocn, Var, CodeModel, CanFail, Context,
        Statement, !Info) :-
    % Generate the rval for the secondary tag.
    ml_gen_info_get_module_info(!.Info, ModuleInfo),
    ml_variable_type(!.Info, Var, VarType),
    ml_gen_var(!.Info, Var, VarLval),
    VarRval = lval(VarLval),
    (
        StagLocn = local,
        STagRval = unop(std_unop(unmkbody), VarRval)
    ;
        StagLocn = remote,
        STagRval = ml_gen_secondary_tag_rval(PrimaryTag,
            VarType, ModuleInfo, VarRval)
    ;
        StagLocn = none,
        unexpected(this_file, "gen_stag_switch: no stag")
    ),

    % Generate the switch on the secondary tag.
    gen_stag_cases(Cases, CodeModel, MLDS_Cases, !Info),
    ml_switch_generate_default(CanFail, CodeModel, Context, Default, !Info),

    % Package up the results into a switch statement.
    Range = range_unknown, % XXX could do better
    SwitchStmt = switch(mlds__native_int_type, STagRval, Range, MLDS_Cases,
        Default),
    MLDS_Context = mlds__make_context(Context),
    ml_simplify_switch(SwitchStmt, MLDS_Context, Statement, !Info).

:- pred gen_stag_cases(stag_goal_list::in, code_model::in,
    list(mlds__switch_case)::out, ml_gen_info::in, ml_gen_info::out) is det.

gen_stag_cases([], _, [], !Info).
gen_stag_cases([Case | Cases], CodeModel, [MLDS_Case | MLDS_Cases], !Info) :-
    gen_stag_case(Case, CodeModel, MLDS_Case, !Info),
    gen_stag_cases(Cases, CodeModel, MLDS_Cases, !Info).

:- pred gen_stag_case(pair(tag_bits, stag_goal)::in,
    code_model::in, mlds__switch_case::out,
    ml_gen_info::in, ml_gen_info::out) is det.

gen_stag_case(Case, CodeModel, MLDS_Case, !Info) :-
    Case = Stag - stag_goal(_ConsId, Goal),
    StagRval = const(int_const(Stag)),
    ml_gen_goal(CodeModel, Goal, Statement, !Info),
    MLDS_Case = [match_value(StagRval)] - Statement.

%-----------------------------------------------------------------------------%

:- func this_file = string.

this_file = "ml_tag_switch.m".

%-----------------------------------------------------------------------------%
