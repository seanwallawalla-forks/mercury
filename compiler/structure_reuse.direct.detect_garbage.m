%-----------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et
%-----------------------------------------------------------------------------%
% Copyright (C) 2006-2010 The University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%-----------------------------------------------------------------------------%
%
% File: structure_reuse.direct.detect_garbage.m.
% Main authors: nancy.
%
% Detect where datastructures become garbage in a given procedure: construct
% a dead cell table.
%
%-----------------------------------------------------------------------------%

:- module transform_hlds.ctgc.structure_reuse.direct.detect_garbage.
:- interface.

:- import_module hlds.hlds_goal.

%-----------------------------------------------------------------------------%

    % Using the sharing table listing all the structure sharing of all
    % the known procedures, return a table of all data structures that may
    % become available for reuse (i.e. cells that may become dead) of a given
    % procedure goal. The table also records the reuse condition associated
    % with each of the dead cells.
    %
:- pred determine_dead_deconstructions(module_info::in, pred_info::in,
    proc_info::in, sharing_as_table::in, hlds_goal::in,
    dead_cell_table::out) is det.

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- implementation.

:- import_module check_hlds.type_util.
:- import_module parse_tree.prog_data.
:- import_module parse_tree.prog_out.
:- import_module transform_hlds.ctgc.datastruct.
:- import_module transform_hlds.ctgc.livedata.

:- import_module bool.
:- import_module io.
:- import_module pair.
:- import_module require.
:- import_module set.
:- import_module string.

%-----------------------------------------------------------------------------%

:- type detect_bg_info
    --->    detect_bg_info(
                module_info     ::  module_info,
                pred_info       ::  pred_info,
                proc_info       ::  proc_info,
                sharing_table   ::  sharing_as_table,
                very_verbose    ::  bool
            ).

:- func detect_bg_info_init(module_info, pred_info, proc_info,
    sharing_as_table) = detect_bg_info.

detect_bg_info_init(ModuleInfo, PredInfo, ProcInfo, SharingTable) = BG :-
    module_info_get_globals(ModuleInfo, Globals),
    globals.lookup_bool_option(Globals, very_verbose, VeryVerbose),
    BG = detect_bg_info(ModuleInfo, PredInfo, ProcInfo, SharingTable,
        VeryVerbose).

determine_dead_deconstructions(ModuleInfo, PredInfo, ProcInfo, SharingTable,
        Goal, DeadCellTable) :-
    Background = detect_bg_info_init(ModuleInfo, PredInfo, ProcInfo,
        SharingTable),
    % In this process we need to know the sharing at each program point,
    % which boils down to reconstructing that sharing information based on the
    % sharing recorded in the sharing table.
    determine_dead_deconstructions_2(Background, Goal,
        sharing_as_init, _, dead_cell_table_init, DeadCellTable),

    % Add a newline after the "progress dots".
    VeryVerbose = Background ^ very_verbose,
    (
        VeryVerbose = yes,
        trace [io(!IO)] (
            io.nl(!IO)
        )
    ;
        VeryVerbose = no
    ).

    % Process a procedure goal, determining the sharing at each subgoal, as
    % well as constructing the table of dead cells.
    %
    % This means:
    %   - at each program point: compute sharing
    %   - at deconstruction unifications: check for a dead cell.
    %
:- pred determine_dead_deconstructions_2(detect_bg_info::in, hlds_goal::in,
    sharing_as::in, sharing_as::out, dead_cell_table::in,
    dead_cell_table::out) is det.

determine_dead_deconstructions_2(Background, TopGoal, !SharingAs,
        !DeadCellTable) :-
    TopGoal = hlds_goal(GoalExpr, GoalInfo),
    ModuleInfo = Background ^ module_info,
    PredInfo = Background ^ pred_info,
    ProcInfo = Background ^ proc_info,
    SharingTable = Background ^ sharing_table,
    (
        GoalExpr = conj(_, Goals),
        list.foldl2(determine_dead_deconstructions_2_with_progress(Background),
            Goals, !SharingAs, !DeadCellTable)
    ;
        GoalExpr = plain_call(PredId, ProcId, ActualVars, _, _, _),
        lookup_sharing_and_comb(ModuleInfo, PredInfo, ProcInfo, SharingTable,
            PredId, ProcId, ActualVars, !SharingAs)
    ;
        GoalExpr = generic_call(GenDetails, CallArgs, Modes, _Detism),
        determine_dead_deconstructions_generic_call(ModuleInfo, ProcInfo,
            GenDetails, CallArgs, Modes, GoalInfo, !SharingAs)
    ;
        GoalExpr = unify(_, _, _, Unification, _),
        unification_verify_reuse(ModuleInfo, ProcInfo, GoalInfo,
            Unification, program_point_init(GoalInfo), !.SharingAs,
            !DeadCellTable),
        !:SharingAs = add_unify_sharing(ModuleInfo, ProcInfo, Unification,
            GoalInfo, !.SharingAs)
    ;
        GoalExpr = disj(Goals),
        determine_dead_deconstructions_2_disj(Background, Goals, !SharingAs,
            !DeadCellTable)
    ;
        GoalExpr = switch(_, _, Cases),
        determine_dead_deconstructions_2_disj(Background,
            list.map(func(C) = G :- (G = C ^ case_goal), Cases), !SharingAs,
            !DeadCellTable)
    ;
        % XXX To check and compare with the theory.
        GoalExpr = negation(_Goal)
    ;
        GoalExpr = scope(Reason, SubGoal),
        ( Reason = from_ground_term(_, from_ground_term_construct) ->
            true
        ;
            determine_dead_deconstructions_2(Background, SubGoal, !SharingAs,
                !DeadCellTable)
        )
    ;
        GoalExpr = if_then_else(_, IfGoal, ThenGoal, ElseGoal),
        determine_dead_deconstructions_2(Background, IfGoal, !.SharingAs,
            IfSharingAs, !DeadCellTable),
        determine_dead_deconstructions_2(Background, ThenGoal, IfSharingAs,
            ThenSharingAs, !DeadCellTable),
        determine_dead_deconstructions_2(Background, ElseGoal, !.SharingAs,
            ElseSharingAs, !DeadCellTable),
        !:SharingAs = sharing_as_least_upper_bound(ModuleInfo, ProcInfo,
            ThenSharingAs, ElseSharingAs)
    ;
        GoalExpr = call_foreign_proc(Attributes, ForeignPredId, ForeignProcId,
            Args, _ExtraArgs, _MaybeTraceRuntimeCond, _Impl),
        ForeignPPId = proc(ForeignPredId, ForeignProcId),
        Context = goal_info_get_context(GoalInfo),
        add_foreign_proc_sharing(ModuleInfo, PredInfo, ProcInfo, ForeignPPId,
            Attributes, Args, Context, !SharingAs)
    ;
        GoalExpr = shorthand(_),
        % These should have been expanded out by now.
        unexpected(detect_garbage.this_file,
            "determine_dead_deconstructions_2: shorthand goal.")
    ).

:- pred determine_dead_deconstructions_2_with_progress(detect_bg_info::in,
    hlds_goal::in, sharing_as::in, sharing_as::out, dead_cell_table::in,
    dead_cell_table::out) is det.

determine_dead_deconstructions_2_with_progress(Background, TopGoal,
        !SharingAs, !DeadCellTable) :-
    VeryVerbose = Background ^ very_verbose,
    (
        VeryVerbose = yes,
        trace [io(!IO)] (
            io.write_char('.', !IO),
            io.flush_output(!IO)
        )
    ;
        VeryVerbose = no
    ),
    determine_dead_deconstructions_2(Background, TopGoal, !SharingAs,
        !DeadCellTable).

:- pred determine_dead_deconstructions_2_disj(detect_bg_info::in,
    hlds_goals::in, sharing_as::in, sharing_as::out,
    dead_cell_table::in, dead_cell_table::out) is det.

determine_dead_deconstructions_2_disj(Background, Goals,
        !SharingAs, !DeadCellTable) :-
    list.foldl2(determine_dead_deconstructions_2_disj_goal(Background,
        !.SharingAs), Goals, !SharingAs, !DeadCellTable).

:- pred determine_dead_deconstructions_2_disj_goal(detect_bg_info::in,
    sharing_as::in, hlds_goal::in, sharing_as::in, sharing_as::out,
    dead_cell_table::in, dead_cell_table::out) is det.

determine_dead_deconstructions_2_disj_goal(Background, SharingBeforeDisj,
        Goal, !SharingAs, !DeadCellTable) :-
    determine_dead_deconstructions_2(Background, Goal, SharingBeforeDisj,
        GoalSharing, !DeadCellTable),
    !:SharingAs = sharing_as_least_upper_bound(Background ^ module_info,
        Background ^ proc_info, !.SharingAs, GoalSharing).

:- pred determine_dead_deconstructions_generic_call(module_info::in,
    proc_info::in, generic_call::in, prog_vars::in, list(mer_mode)::in,
    hlds_goal_info::in, sharing_as::in, sharing_as::out) is det.

determine_dead_deconstructions_generic_call(ModuleInfo, ProcInfo,
        GenDetails, CallArgs, Modes, GoalInfo, !SharingAs) :-
    (
        ( GenDetails = higher_order(_, _, _, _)
        ; GenDetails = class_method(_, _, _, _)
        ),
        proc_info_get_vartypes(ProcInfo, CallerVarTypes),
        map.apply_to_list(CallArgs, CallerVarTypes, ActualTypes),
        (
            bottom_sharing_is_safe_approximation_by_args(ModuleInfo, Modes,
                ActualTypes)
        ->
            SetToTop = no
        ;
            SetToTop = yes
        )
    ;
        ( GenDetails = event_call(_) % XXX too conservative
        ; GenDetails = cast(_)
        ),
        SetToTop = yes
    ),
    (
        SetToTop = yes,
        Context = goal_info_get_context(GoalInfo),
        context_to_string(Context, ContextString),
        !:SharingAs = sharing_as_top_sharing_accumulate(
            top_cannot_improve("generic call (" ++ ContextString ++ ")"),
            !.SharingAs)
    ;
        SetToTop = no
    ).

    % Verify whether the unification is a deconstruction in which the
    % deconstructed data structure becomes garbage (under some reuse
    % conditions).
    %
    % XXX Different implementation from the reuse-branch implementation.
    %
:- pred unification_verify_reuse(module_info::in, proc_info::in,
    hlds_goal_info::in, unification::in, program_point::in,
    sharing_as::in, dead_cell_table::in, dead_cell_table::out) is det.

unification_verify_reuse(ModuleInfo, ProcInfo, GoalInfo, Unification,
        PP, Sharing, !DeadCellTable):-
    (
        Unification = deconstruct(Var, ConsId, _, _, _, _),
        LFU = goal_info_get_lfu(GoalInfo),
        LBU = goal_info_get_lbu(GoalInfo),
        (
            % Reuse is only relevant for real constructors, with
            % arity different from 0.
            ConsId = cons(_, Arity, _),
            Arity \= 0,

            % No-tag values don't have a cell to reuse.
            proc_info_get_vartypes(ProcInfo, VarTypes),
            map.lookup(VarTypes, Var, Type),
            \+ type_is_no_tag_type(ModuleInfo, Type),

            % Check if the top cell datastructure of Var is not live.
            % If Sharing is top, then everything should automatically
            % be considered live, hence no reuse possible.
            \+ sharing_as_is_top(Sharing),

            % Check the live set of data structures at this program point.
            var_not_live(ModuleInfo, ProcInfo, GoalInfo, Sharing, Var)
        ->
            % If all the above conditions are met, then the top
            % cell data structure based on Var is dead right after
            % this deconstruction, hence, may be involved with
            % structure reuse.
            NewCondition = reuse_condition_init(ModuleInfo,
                ProcInfo, Var, LFU, LBU, Sharing),
            dead_cell_table_set(PP, NewCondition, !DeadCellTable)
        ;
            true
        )
    ;
        Unification = construct(_, _, _, _, _, _, _)
    ;
        Unification = assign(_, _)
    ;
        Unification = simple_test(_, _)
    ;
        Unification = complicated_unify(_, _, _),
        unexpected(detect_garbage.this_file, "unification_verify_reuse: " ++
            "complicated_unify/3 encountered.")
    ).

:- pred var_not_live(module_info::in, proc_info::in, hlds_goal_info::in,
    sharing_as::in, prog_var::in) is semidet.

var_not_live(ModuleInfo, ProcInfo, GoalInfo, Sharing, Var) :-
    LiveData = livedata_init_at_goal(ModuleInfo, ProcInfo, GoalInfo, Sharing),
    nodes_are_not_live(ModuleInfo, ProcInfo, [datastruct_init(Var)], LiveData,
        NotLive),
    (
        NotLive = nodes_are_live([])
    ;
        ( NotLive = nodes_all_live
        ; NotLive = nodes_are_live([_ | _])
        ),
        fail
    ).

%-----------------------------------------------------------------------------%

:- func this_file = string.

this_file = "structure_sharing.direct.detect_garbage.m".

%-----------------------------------------------------------------------------%
:- end_module transform_hlds.ctgc.structure_reuse.direct.detect_garbage.
%-----------------------------------------------------------------------------%
