%---------------------------------------------------------------------------%
% Copyright (C) 1997-2005 University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%---------------------------------------------------------------------------%
%
% File: stack_layout.m.
% Main authors: trd, zs.
%
% This module generates label, procedure, module and closure layout structures
% for code in the current module for the LLDS backend. Layout structures are
% used by the parts of the runtime system that need to look at the stacks
% (and sometimes the registers) and make sense of their contents. The parts
% of the runtime system that need to do this include exception handling,
% the debugger, and (eventually) the accurate garbage collector.
%
% The tables we generate are mostly of (Mercury) types defined in layout.m,
% which are turned into C code (global variable declarations and
% initializations) by layout_out.m.
%
% The C types of the structures we generate are defined and documented in
% runtime/mercury_stack_layout.h.
%
%---------------------------------------------------------------------------%

:- module ll_backend__stack_layout.

:- interface.

:- import_module hlds__hlds_module.
:- import_module ll_backend__continuation_info.
:- import_module ll_backend__global_data.
:- import_module ll_backend__llds.
:- import_module mdbcomp__prim_data.
:- import_module parse_tree__prog_data.

:- import_module list, assoc_list, map.

:- pred stack_layout__generate_llds(module_info::in,
	global_data::in, global_data::out,
	list(comp_gen_c_data)::out, map(label, data_addr)::out) is det.

:- pred stack_layout__construct_closure_layout(proc_label::in, int::in,
	closure_layout_info::in, proc_label::in, module_name::in,
	string::in, int::in, string::in,
	static_cell_info::in, static_cell_info::out,
	assoc_list(rval, llds_type)::out, comp_gen_c_data::out) is det.

	% Construct a representation of a variable location as a 32-bit
	% integer.
:- pred stack_layout__represent_locn_as_int(layout_locn::in, int::out) is det.

	% Construct a representation of the interface determinism of a
	% procedure.
:- pred stack_layout__represent_determinism_rval(determinism::in,
		rval::out) is det.

:- implementation.

:- import_module backend_libs__rtti.
:- import_module check_hlds__type_util.
:- import_module hlds__code_model.
:- import_module hlds__goal_util.
:- import_module hlds__hlds_data.
:- import_module hlds__hlds_goal.
:- import_module hlds__hlds_pred.
:- import_module hlds__instmap.
:- import_module libs__globals.
:- import_module libs__options.
:- import_module libs__trace_params.
:- import_module ll_backend__code_util.
:- import_module ll_backend__layout.
:- import_module ll_backend__layout_out.
:- import_module ll_backend__ll_pseudo_type_info.
:- import_module ll_backend__llds_out.
:- import_module ll_backend__prog_rep.
:- import_module ll_backend__static_term.
:- import_module ll_backend__trace.
:- import_module parse_tree__prog_out.
:- import_module parse_tree__prog_util.

:- import_module std_util, bool, char, string, int, require.
:- import_module map, term, set, counter, varset.

%---------------------------------------------------------------------------%

	% Process all the continuation information stored in the HLDS,
	% converting it into LLDS data structures.

stack_layout__generate_llds(ModuleInfo0, !GlobalData, Layouts, LayoutLabels) :-
	global_data_get_all_proc_layouts(!.GlobalData, ProcLayoutList),
	module_info_globals(ModuleInfo0, Globals),
	globals__lookup_bool_option(Globals, agc_stack_layout, AgcLayout),
	globals__lookup_bool_option(Globals, trace_stack_layout, TraceLayout),
	globals__lookup_bool_option(Globals, procid_stack_layout,
		ProcIdLayout),
	globals__get_trace_level(Globals, TraceLevel),
	globals__get_trace_suppress(Globals, TraceSuppress),
	globals__have_static_code_addresses(Globals, StaticCodeAddr),
	map__init(LayoutLabels0),

	map__init(StringMap0),
	map__init(LabelTables0),
	StringTable0 = string_table(StringMap0, [], 0),
	global_data_get_static_cell_info(!.GlobalData, StaticCellInfo0),
	counter__init(1, LabelCounter0),
	LayoutInfo0 = stack_layout_info(ModuleInfo0,
		AgcLayout, TraceLayout, ProcIdLayout, StaticCodeAddr,
		LabelCounter0, [], [], [], LayoutLabels0, [],
		StringTable0, LabelTables0, StaticCellInfo0),
	stack_layout__lookup_string_in_table("", _, LayoutInfo0, LayoutInfo1),
	stack_layout__lookup_string_in_table("<too many variables>", _,
		LayoutInfo1, LayoutInfo2),
	list__foldl(stack_layout__construct_layouts, ProcLayoutList,
		LayoutInfo2, LayoutInfo),
	LabelsCounter = LayoutInfo ^ label_counter,
	counter__allocate(NumLabels, LabelsCounter, _),
	TableIoDecls = LayoutInfo ^ table_infos,
	ProcLayouts = LayoutInfo ^ proc_layouts,
	InternalLayouts = LayoutInfo ^ internal_layouts,
	LayoutLabels = LayoutInfo ^ label_set,
	ProcLayoutNames = LayoutInfo ^ proc_layout_name_list,
	StringTable = LayoutInfo ^ string_table,
	LabelTables = LayoutInfo ^ label_tables,
	global_data_set_static_cell_info(LayoutInfo ^ static_cell_info,
		!GlobalData),
	StringTable = string_table(_, RevStringList, StringOffset),
	list__reverse(RevStringList, StringList),
	stack_layout__concat_string_list(StringList, StringOffset,
		ConcatStrings),

	list__condense([TableIoDecls, ProcLayouts, InternalLayouts],
		Layouts0),
	(
		TraceLayout = yes,
		module_info_name(ModuleInfo0, ModuleName),
		globals__lookup_bool_option(Globals, rtti_line_numbers,
			LineNumbers),
		(
			LineNumbers = yes,
			EffLabelTables = LabelTables
		;
			LineNumbers = no,
			map__init(EffLabelTables)
		),
		stack_layout__format_label_tables(EffLabelTables,
			SourceFileLayouts),
		SuppressedEvents = encode_suppressed_events(TraceSuppress),
		ModuleLayout = layout_data(module_layout_data(ModuleName,
			StringOffset, ConcatStrings, ProcLayoutNames,
			SourceFileLayouts, TraceLevel, SuppressedEvents,
			NumLabels)),
		Layouts = [ModuleLayout | Layouts0]
	;
		TraceLayout = no,
		Layouts = Layouts0
	).

:- pred stack_layout__valid_proc_layout(proc_layout_info::in) is semidet.

stack_layout__valid_proc_layout(ProcLayoutInfo) :-
	EntryLabel = ProcLayoutInfo ^ entry_label,
	ProcLabel = get_proc_label(EntryLabel),
	(
		ProcLabel = proc(_, _, DeclModule, Name, Arity, _),
		\+ no_type_info_builtin(DeclModule, Name, Arity)
	;
		ProcLabel = special_proc(_, _, _, _, _, _)
	).

%---------------------------------------------------------------------------%

	% concat_string_list appends a list of strings together,
	% appending a null character after each string.
	% The resulting string will contain embedded null characters,
:- pred stack_layout__concat_string_list(list(string)::in, int::in,
	string_with_0s::out) is det.

concat_string_list(Strings, Len, string_with_0s(Result)) :-
	concat_string_list_2(Strings, Len, Result).

:- pred stack_layout__concat_string_list_2(list(string)::in, int::in,
	string::out) is det.

:- pragma foreign_decl("C", "
	#include ""mercury_tags.h""	/* for MR_list_*() */
	#include ""mercury_heap.h""	/* for MR_offset_incr_hp_atomic*() */
	#include ""mercury_misc.h""	/* for MR_fatal_error() */
").

:- pragma foreign_proc("C",
	stack_layout__concat_string_list_2(StringList::in, ArenaSize::in,
		Arena::out),
	[will_not_call_mercury, promise_pure, thread_safe],
"{
	MR_Word		cur_node;
	MR_Integer	cur_offset;
	MR_Word		tmp;

	MR_offset_incr_hp_atomic(tmp, 0,
		(ArenaSize + sizeof(MR_Word)) / sizeof(MR_Word));
	Arena = (char *) tmp;

	cur_offset = 0;
	cur_node = StringList;

	while (! MR_list_is_empty(cur_node)) {
		(void) strcpy(&Arena[cur_offset],
			(char *) MR_list_head(cur_node));
		cur_offset += strlen((char *) MR_list_head(cur_node)) + 1;
		cur_node = MR_list_tail(cur_node);
	}

	if (cur_offset != ArenaSize) {
		char	msg[256];

		sprintf(msg, ""internal error in creating string table;\\n""
			""cur_offset = %ld, ArenaSize = %ld\\n"",
			(long) cur_offset, (long) ArenaSize);
		MR_fatal_error(msg);
	}
}").

% This version is only used if there is no matching foreign_proc version.
% Note that this version only works if the Mercury implementation's
% string representation allows strings to contain embedded null
% characters.  So we check that.
concat_string_list_2(StringsList, _Len, StringWithNulls) :-
	(
		char__to_int(NullChar, 0),
		NullCharString = string__char_to_string(NullChar),
		string__length(NullCharString, 1)
	->
		StringsWithNullsList = list__map(func(S) = S ++ NullCharString,
			StringsList),
		StringWithNulls = string__append_list(StringsWithNullsList)
	;
		% the Mercury implementation's string representation
		% doesn't support strings containing null characters
		private_builtin.sorry("stack_layout.concat_string_list")
	).

%---------------------------------------------------------------------------%

:- pred stack_layout__format_label_tables(map(string, label_table)::in,
	list(file_layout_data)::out) is det.

stack_layout__format_label_tables(LabelTableMap, SourceFileLayouts) :-
	map__to_assoc_list(LabelTableMap, LabelTableList),
	list__map(stack_layout__format_label_table, LabelTableList,
		SourceFileLayouts).

:- pred stack_layout__format_label_table(pair(string, label_table)::in,
	file_layout_data::out) is det.

stack_layout__format_label_table(FileName - LineNoMap,
		file_layout_data(FileName, FilteredList)) :-
		% This step should produce a list ordered on line numbers.
	map__to_assoc_list(LineNoMap, LineNoList),
		% And this step should preserve that order.
	stack_layout__flatten_label_table(LineNoList, [], FlatLineNoList),
	Filter = (pred(LineNoInfo::in, FilteredLineNoInfo::out) is det :-
		LineNoInfo = LineNo - (Label - _IsReturn),
		FilteredLineNoInfo = LineNo - Label
	),
	list__map(Filter, FlatLineNoList, FilteredList).

:- pred stack_layout__flatten_label_table(
	assoc_list(int, list(line_no_info))::in,
	assoc_list(int, line_no_info)::in,
	assoc_list(int, line_no_info)::out) is det.

stack_layout__flatten_label_table([], RevList, List) :-
	list__reverse(RevList, List).
stack_layout__flatten_label_table([LineNo - LinesInfos | Lines],
		RevList0, List) :-
	list__foldl(stack_layout__add_line_no(LineNo), LinesInfos,
		RevList0, RevList1),
	stack_layout__flatten_label_table(Lines, RevList1, List).

:- pred stack_layout__add_line_no(int::in, line_no_info::in,
	assoc_list(int, line_no_info)::in,
	assoc_list(int, line_no_info)::out) is det.

stack_layout__add_line_no(LineNo, LineInfo, RevList0, RevList) :-
	RevList = [LineNo - LineInfo | RevList0].

%---------------------------------------------------------------------------%

	% Construct the layouts that concern a single procedure:
	% the procedure-specific layout and the layouts of the labels
	% inside that procedure. Also update the module-wide label table
	% with the labels defined in this procedure.

:- pred stack_layout__construct_layouts(proc_layout_info::in,
	stack_layout_info::in, stack_layout_info::out) is det.

stack_layout__construct_layouts(ProcLayoutInfo, !Info) :-
	ProcLayoutInfo = proc_layout_info(RttiProcLabel, EntryLabel, _Detism,
		_StackSlots, _SuccipLoc, _EvalMethod, _EffTraceLevel,
		_MaybeCallLabel, _MaxTraceReg, HeadVars, _ArgModes, MaybeGoal,
		_InstMap, _TraceSlotInfo, ForceProcIdLayout, VarSet, _VarTypes,
		InternalMap, MaybeTableIoDecl, _NeedsAllNames,
		_MaybeDeepProfInfo),
	map__to_assoc_list(InternalMap, Internals),
	compute_var_number_map(HeadVars, VarSet, Internals, MaybeGoal,
		VarNumMap),

	ProcLabel = get_proc_label(EntryLabel),
	stack_layout__get_procid_stack_layout(!.Info, ProcIdLayout0),
	bool__or(ProcIdLayout0, ForceProcIdLayout, ProcIdLayout),
	(
		( ProcIdLayout = yes
		; MaybeTableIoDecl = yes(_)
		)
	->
		Kind = proc_layout_proc_id(proc_label_user_or_uci(ProcLabel))
	;
		Kind = proc_layout_traversal
	),

	ProcLayoutName = proc_layout(RttiProcLabel, Kind),

	(
		( !.Info ^ agc_stack_layout = yes
		; !.Info ^ trace_stack_layout = yes
		),
		valid_proc_layout(ProcLayoutInfo)
	->
		list__map_foldl(stack_layout__construct_internal_layout(
			ProcLabel, ProcLayoutName, VarNumMap),
			Internals, InternalLayouts, !Info)
	;
		InternalLayouts = []
	),

	stack_layout__get_label_tables(!.Info, LabelTables0),
	list__foldl(stack_layout__update_label_table, InternalLayouts,
		LabelTables0, LabelTables),
	stack_layout__set_label_tables(LabelTables, !Info),
	stack_layout__construct_proc_layout(ProcLayoutInfo, Kind, VarNumMap,
		!Info).

%---------------------------------------------------------------------------%

	% Add the given label layout to the module-wide label tables.

:- pred stack_layout__update_label_table(
	{proc_label, int, label_vars, internal_layout_info}::in,
	map(string, label_table)::in, map(string, label_table)::out) is det.

stack_layout__update_label_table(
		{ProcLabel, LabelNum, LabelVars, InternalInfo},
		!LabelTables) :-
	InternalInfo = internal_layout_info(Port, _, Return),
	(
		Return = yes(return_layout_info(TargetsContexts, _)),
		stack_layout__find_valid_return_context(TargetsContexts,
			Target, Context, _GoalPath)
	->
		( Target = label(TargetLabel) ->
			IsReturn = known_callee(TargetLabel)
		;
			IsReturn = unknown_callee
		),
		stack_layout__update_label_table_2(ProcLabel, LabelNum,
			LabelVars, Context, IsReturn, !LabelTables)
	;
		Port = yes(trace_port_layout_info(Context, _, _, _, _)),
		stack_layout__context_is_valid(Context)
	->
		stack_layout__update_label_table_2(ProcLabel, LabelNum,
			LabelVars, Context, not_a_return, !LabelTables)
	;
		true
	).

:- pred stack_layout__update_label_table_2(proc_label::in, int::in,
	label_vars::in, context::in, is_label_return::in,
	map(string, label_table)::in, map(string, label_table)::out) is det.

stack_layout__update_label_table_2(ProcLabel, LabelNum, LabelVars, Context,
		IsReturn, !LabelTables) :-
	term__context_file(Context, File),
	term__context_line(Context, Line),
	( map__search(!.LabelTables, File, LabelTable0) ->
		LabelLayout = label_layout(ProcLabel, LabelNum, LabelVars),
		( map__search(LabelTable0, Line, LineInfo0) ->
			LineInfo = [LabelLayout - IsReturn | LineInfo0],
			map__det_update(LabelTable0, Line, LineInfo,
				LabelTable),
			map__det_update(!.LabelTables, File, LabelTable,
				!:LabelTables)
		;
			LineInfo = [LabelLayout - IsReturn],
			map__det_insert(LabelTable0, Line, LineInfo,
				LabelTable),
			map__det_update(!.LabelTables, File, LabelTable,
				!:LabelTables)
		)
	; stack_layout__context_is_valid(Context) ->
		map__init(LabelTable0),
		LabelLayout = label_layout(ProcLabel, LabelNum, LabelVars),
		LineInfo = [LabelLayout - IsReturn],
		map__det_insert(LabelTable0, Line, LineInfo, LabelTable),
		map__det_insert(!.LabelTables, File, LabelTable, !:LabelTables)
	;
			% We don't have a valid context for this label,
			% so we don't enter it into any tables.
		true
	).

:- pred stack_layout__find_valid_return_context(
	assoc_list(code_addr, pair(prog_context, goal_path))::in,
	code_addr::out, prog_context::out, goal_path::out) is semidet.

stack_layout__find_valid_return_context([TargetContext | TargetContexts],
		ValidTarget, ValidContext, ValidGoalPath) :-
	TargetContext = Target - (Context - GoalPath),
	( stack_layout__context_is_valid(Context) ->
		ValidTarget = Target,
		ValidContext = Context,
		ValidGoalPath = GoalPath
	;
		stack_layout__find_valid_return_context(TargetContexts,
			ValidTarget, ValidContext, ValidGoalPath)
	).

:- pred stack_layout__context_is_valid(prog_context::in) is semidet.

stack_layout__context_is_valid(Context) :-
	term__context_file(Context, File),
	term__context_line(Context, Line),
	File \= "",
	Line > 0.

%---------------------------------------------------------------------------%

:- pred stack_layout__construct_proc_traversal(label::in, determinism::in,
	int::in, maybe(int)::in, proc_layout_stack_traversal::out,
	stack_layout_info::in, stack_layout_info::out) is det.

stack_layout__construct_proc_traversal(EntryLabel, Detism, NumStackSlots,
		MaybeSuccipLoc, Traversal, !Info) :-
	(
		MaybeSuccipLoc = yes(Location),
		( determinism_components(Detism, _, at_most_many) ->
			SuccipLval = framevar(Location)
		;
			SuccipLval = stackvar(Location)
		),
		stack_layout__represent_locn_as_int(direct(SuccipLval),
			SuccipInt),
		MaybeSuccipInt = yes(SuccipInt)
	;
		MaybeSuccipLoc = no,
			% Use a dummy location if there is no succip slot
			% on the stack.
			%
			% This case can arise in two circumstances.
			% First, procedures that use the nondet stack
			% have a special slot for the succip, so the
			% succip is not stored in a general purpose
			% slot. Second, procedures that use the det stack
			% but which do not call other procedures
			% do not save the succip on the stack.
			%
			% The tracing system does not care about the
			% location of the saved succip. The accurate
			% garbage collector does. It should know from
			% the determinism that the procedure uses the
			% nondet stack, which takes care of the first
			% possibility above. Procedures that do not call
			% other procedures do not establish resumption
			% points and thus agc is not interested in them.
			% As far as stack dumps go, calling error counts
			% as a call, so any procedure that may call error
			% (directly or indirectly) will have its saved succip
			% location recorded, so the stack dump will work.
			%
			% Future uses of stack layouts will have to have
			% similar constraints.
		MaybeSuccipInt = no
	),
	stack_layout__get_static_code_addresses(!.Info, StaticCodeAddr),
	(
		StaticCodeAddr = yes,
		MaybeEntryLabel = yes(EntryLabel)
	;
		StaticCodeAddr = no,
		MaybeEntryLabel = no
	),
	Traversal = proc_layout_stack_traversal(MaybeEntryLabel,
		MaybeSuccipInt, NumStackSlots, Detism).

	% Construct a procedure-specific layout.

:- pred stack_layout__construct_proc_layout(proc_layout_info::in,
	proc_layout_kind::in, var_num_map::in,
	stack_layout_info::in, stack_layout_info::out) is det.

stack_layout__construct_proc_layout(ProcLayoutInfo, Kind, VarNumMap, !Info) :-
	ProcLayoutInfo = proc_layout_info(RttiProcLabel, EntryLabel, Detism,
		StackSlots, SuccipLoc, EvalMethod, EffTraceLevel,
		MaybeCallLabel, MaxTraceReg, HeadVars, ArgModes, MaybeGoal,
		InstMap, TraceSlotInfo, _ForceProcIdLayout, VarSet, VarTypes,
		_InternalMap, MaybeTableInfo, NeedsAllNames, MaybeProcStatic),
	stack_layout__construct_proc_traversal(EntryLabel, Detism, StackSlots,
		SuccipLoc, Traversal, !Info),
	(
		Kind = proc_layout_traversal,
		More = no_proc_id
	;
		Kind = proc_layout_proc_id(_),
		stack_layout__get_trace_stack_layout(!.Info, TraceStackLayout),
		(
			TraceStackLayout = yes,
			given_trace_level_is_none(EffTraceLevel) = no,
			valid_proc_layout(ProcLayoutInfo)
		->
			stack_layout__construct_trace_layout(RttiProcLabel,
				EvalMethod, EffTraceLevel, MaybeCallLabel,
				MaxTraceReg, HeadVars, ArgModes, MaybeGoal,
				InstMap, TraceSlotInfo, VarSet, VarTypes,
				MaybeTableInfo, NeedsAllNames, VarNumMap,
				ExecTrace, !Info),
			MaybeExecTrace = yes(ExecTrace)
		;
			MaybeExecTrace = no
		),
		More = proc_id(MaybeProcStatic, MaybeExecTrace)
	),
	ProcLayout = proc_layout_data(RttiProcLabel, Traversal, More),
	Data = layout_data(ProcLayout),
	LayoutName = proc_layout(RttiProcLabel, Kind),
	stack_layout__add_proc_layout_data(Data, LayoutName, EntryLabel,
		!Info),
	(
		MaybeTableInfo = no
	;
		MaybeTableInfo = yes(TableInfo),
		stack_layout__get_static_cell_info(!.Info, StaticCellInfo0),
		stack_layout__make_table_data(RttiProcLabel, Kind,
			TableInfo, TableData,
			StaticCellInfo0, StaticCellInfo),
		stack_layout__set_static_cell_info(StaticCellInfo, !Info),
		stack_layout__add_table_data(TableData, !Info)
	).

:- pred stack_layout__construct_trace_layout(rtti_proc_label::in,
	eval_method::in, trace_level::in, maybe(label)::in, int::in,
	list(prog_var)::in, list(mode)::in, maybe(hlds_goal)::in,
	instmap::in, trace_slot_info::in, prog_varset::in, vartypes::in,
	maybe(proc_table_info)::in, bool::in, var_num_map::in,
	proc_layout_exec_trace::out,
	stack_layout_info::in, stack_layout_info::out) is det.

stack_layout__construct_trace_layout(RttiProcLabel, EvalMethod, EffTraceLevel,
		MaybeCallLabel, MaxTraceReg, HeadVars, ArgModes,
		MaybeGoal, InstMap, TraceSlotInfo, _VarSet, VarTypes,
		MaybeTableInfo, NeedsAllNames, VarNumMap, ExecTrace, !Info) :-
	stack_layout__construct_var_name_vector(VarNumMap,
		NeedsAllNames, MaxVarNum, VarNameVector, !Info),
	list__map(convert_var_to_int(VarNumMap), HeadVars, HeadVarNumVector),
	ModuleInfo = !.Info ^ module_info,
	(
		MaybeGoal = no,
		MaybeProcRepRval = no
	;
		MaybeGoal = yes(Goal),
		ProcRep = prog_rep__represent_proc(HeadVars, Goal, InstMap,
			VarTypes, VarNumMap, ModuleInfo),
		type_to_univ(ProcRep, ProcRepUniv),
		StaticCellInfo0 = !.Info ^ static_cell_info,
		static_term__term_to_rval(ProcRepUniv, ProcRepRval,
			StaticCellInfo0, StaticCellInfo),
		MaybeProcRepRval = yes(ProcRepRval),
		!:Info = !.Info ^ static_cell_info := StaticCellInfo
	),
	(
		MaybeCallLabel = yes(CallLabelPrime),
		CallLabel = CallLabelPrime
	;
		MaybeCallLabel = no,
		error("stack_layout__construct_trace_layout: " ++
			"call label not present")
	),
	TraceSlotInfo = trace_slot_info(MaybeFromFullSlot, MaybeIoSeqSlot,
		MaybeTrailSlots, MaybeMaxfrSlot, MaybeCallTableSlot),
		% The label associated with an event must have variable info.
	(
		CallLabel = internal(CallLabelNum, CallProcLabel)
	;
		CallLabel = entry(_, _),
		error("stack_layout__construct_trace_layout: entry call label")
	),
	CallLabelLayout = label_layout(CallProcLabel, CallLabelNum,
		label_has_var_info),
	(
		MaybeTableInfo = no,
		MaybeTableName = no
	;
		MaybeTableInfo = yes(TableInfo),
		(
			TableInfo = table_io_decl_info(_),
			MaybeTableName = yes(table_io_decl(RttiProcLabel))
		;
			TableInfo = table_gen_info(_, _, _, _),
			MaybeTableName = yes(table_gen_info(RttiProcLabel))
		)
	),
	encode_exec_trace_flags(ModuleInfo, HeadVars, ArgModes, VarTypes,
		0, Flags),
	ExecTrace = proc_layout_exec_trace(CallLabelLayout, MaybeProcRepRval,
		MaybeTableName, HeadVarNumVector, VarNameVector,
		MaxVarNum, MaxTraceReg, MaybeFromFullSlot, MaybeIoSeqSlot,
		MaybeTrailSlots, MaybeMaxfrSlot, EvalMethod,
		MaybeCallTableSlot, EffTraceLevel, Flags).

:- pred encode_exec_trace_flags(module_info::in, list(prog_var)::in,
	list(mode)::in, vartypes::in, int::in, int::out) is det.

encode_exec_trace_flags(ModuleInfo, HeadVars, ArgModes, VarTypes, !Flags) :-
	(
		proc_info_has_io_state_pair_from_details(ModuleInfo, HeadVars, ArgModes,
			VarTypes, _, _)
	->
		!:Flags = !.Flags + 1
	;
		true
	).

:- pred stack_layout__construct_var_name_vector(var_num_map::in,
	bool::in, int::out, list(int)::out,
	stack_layout_info::in, stack_layout_info::out) is det.

stack_layout__construct_var_name_vector(VarNumMap, NeedsAllNames, MaxVarNum,
		Offsets, !Info) :-
	map__values(VarNumMap, VarNames0),
	(
		NeedsAllNames = yes,
		VarNames = VarNames0
	;
		NeedsAllNames = no,
		list__filter(var_has_name, VarNames0, VarNames)
	),
	list__sort(VarNames, SortedVarNames),
	( SortedVarNames = [FirstVarNum - _ | _] ->
		MaxVarNum0 = FirstVarNum,
		stack_layout__construct_var_name_rvals(SortedVarNames, 1,
			MaxVarNum0, MaxVarNum, Offsets, !Info)
	;
			% Since variable numbers start at 1, MaxVarNum = 0
			% implies an empty array.
		MaxVarNum = 0,
		Offsets = []
	).

:- pred var_has_name(pair(int, string)::in) is semidet.

var_has_name(_VarNum - VarName) :-
	VarName \= "".

:- pred stack_layout__construct_var_name_rvals(assoc_list(int, string)::in,
	int::in, int::in, int::out, list(int)::out,
	stack_layout_info::in, stack_layout_info::out) is det.

stack_layout__construct_var_name_rvals([], _CurNum, MaxNum, MaxNum, [], !Info).
stack_layout__construct_var_name_rvals([Var - Name | VarNamesTail], CurNum,
		!MaxNum, [Offset | OffsetsTail], !Info) :-
	( Var = CurNum ->
		stack_layout__lookup_string_in_table(Name, Offset, !Info),
		!:MaxNum = Var,
		VarNames = VarNamesTail
	;
		Offset = 0,
		VarNames = [Var - Name | VarNamesTail]
	),
	stack_layout__construct_var_name_rvals(VarNames, CurNum + 1,
		!MaxNum, OffsetsTail, !Info).

%---------------------------------------------------------------------------%

:- pred compute_var_number_map(list(prog_var)::in, prog_varset::in,
	assoc_list(int, internal_layout_info)::in, maybe(hlds_goal)::in,
	var_num_map::out) is det.

compute_var_number_map(HeadVars, VarSet, Internals, MaybeGoal, VarNumMap) :-
	VarNumMap0 = map__init,
	Counter0 = counter__init(1),	% to match term__var_supply_init
	(
		MaybeGoal = yes(Goal),
		goal_util__goal_vars(Goal, GoalVarSet),
		set__to_sorted_list(GoalVarSet, GoalVars),
		list__foldl2(add_var_to_var_number_map(VarSet), GoalVars,
			VarNumMap0, VarNumMap1, Counter0, Counter1)
	;
		MaybeGoal = no,
		VarNumMap1 = VarNumMap0,
		Counter1 = Counter0
	),
	list__foldl2(add_var_to_var_number_map(VarSet), HeadVars,
		VarNumMap1, VarNumMap2, Counter1, Counter2),
	list__foldl2(internal_var_number_map, Internals, VarNumMap2, VarNumMap,
		Counter2, _Counter).

:- pred internal_var_number_map(pair(int, internal_layout_info)::in,
	var_num_map::in, var_num_map::out, counter::in, counter::out) is det.

internal_var_number_map(_Label - Internal, !VarNumMap, !Counter) :-
	Internal = internal_layout_info(MaybeTrace, MaybeResume, MaybeReturn),
	(
		MaybeTrace = yes(Trace),
		Trace = trace_port_layout_info(_, _, _, _, TraceLayout),
		label_layout_var_number_map(TraceLayout, !VarNumMap, !Counter)
	;
		MaybeTrace = no
	),
	(
		MaybeResume = yes(ResumeLayout),
		label_layout_var_number_map(ResumeLayout, !VarNumMap, !Counter)
	;
		MaybeResume = no
	),
	(
		MaybeReturn = yes(Return),
		Return = return_layout_info(_, ReturnLayout),
		label_layout_var_number_map(ReturnLayout, !VarNumMap, !Counter)
	;
		MaybeReturn = no
	).

:- pred label_layout_var_number_map(layout_label_info::in,
	var_num_map::in, var_num_map::out, counter::in, counter::out) is det.

label_layout_var_number_map(LabelLayout, !VarNumMap, !Counter) :-
	LabelLayout = layout_label_info(VarInfoSet, _),
	VarInfos = set__to_sorted_list(VarInfoSet),
	FindVar = (pred(VarInfo::in, Var - Name::out) is semidet :-
		VarInfo = layout_var_info(_, LiveValueType, _),
		LiveValueType = var(Var, Name, _, _)
	),
	list__filter_map(FindVar, VarInfos, VarsNames),
	list__foldl2(add_named_var_to_var_number_map, VarsNames,
		!VarNumMap, !Counter).

:- pred add_var_to_var_number_map(prog_varset::in, prog_var::in,
	var_num_map::in, var_num_map::out, counter::in, counter::out) is det.

add_var_to_var_number_map(VarSet, Var, !VarNumMap, !Counter) :-
	( varset__search_name(VarSet, Var, VarName) ->
		Name = VarName
	;
		Name = ""
	),
	add_named_var_to_var_number_map(Var - Name, !VarNumMap, !Counter).

:- pred add_named_var_to_var_number_map(pair(prog_var, string)::in,
	var_num_map::in, var_num_map::out, counter::in, counter::out) is det.

add_named_var_to_var_number_map(Var - Name, !VarNumMap, !Counter) :-
	( map__search(!.VarNumMap, Var, _) ->
		% Name shouldn't differ from the name recorded in !.VarNumMap.
		true
	;
		counter__allocate(VarNum, !Counter),
		map__det_insert(!.VarNumMap, Var, VarNum - Name, !:VarNumMap)
	).

%---------------------------------------------------------------------------%

	% Construct the layout describing a single internal label
	% for accurate GC and/or execution tracing.

:- pred stack_layout__construct_internal_layout(proc_label::in,
	layout_name::in, var_num_map::in, pair(int, internal_layout_info)::in,
	{proc_label, int, label_vars, internal_layout_info}::out,
	stack_layout_info::in, stack_layout_info::out) is det.

stack_layout__construct_internal_layout(ProcLabel, ProcLayoutName, VarNumMap,
		LabelNum - Internal, LabelLayout, !Info) :-
	Internal = internal_layout_info(Trace, Resume, Return),
	(
		Trace = no,
		set__init(TraceLiveVarSet),
		map__init(TraceTypeVarMap)
	;
		Trace = yes(trace_port_layout_info(_,_,_,_, TraceLayout)),
		TraceLayout = layout_label_info(TraceLiveVarSet,
			TraceTypeVarMap)
	),
	(
		Resume = no,
		set__init(ResumeLiveVarSet),
		map__init(ResumeTypeVarMap)
	;
		Resume = yes(ResumeLayout),
		ResumeLayout = layout_label_info(ResumeLiveVarSet,
			ResumeTypeVarMap)
	),
	(
		Trace = yes(trace_port_layout_info(_, Port, IsHidden,
			GoalPath, _)),
		Return = no,
		MaybePort = yes(Port),
		MaybeIsHidden = yes(IsHidden),
		goal_path_to_string(GoalPath, GoalPathStr),
		stack_layout__lookup_string_in_table(GoalPathStr, GoalPathNum,
			!Info),
		MaybeGoalPath = yes(GoalPathNum)
	;
		Trace = no,
		Return = yes(ReturnInfo),
			% We only ever use the port fields of these layout
			% structures when we process exception events.
			% (Since exception events are interface events,
			% the goal path field is not meaningful then.)
		MaybePort = yes(exception),
		MaybeIsHidden = yes(no),
			% We only ever use the goal path fields of these
			% layout structures when we process "fail" commands
			% in the debugger.
		ReturnInfo = return_layout_info(TargetsContexts, _),
		(
			stack_layout__find_valid_return_context(
				TargetsContexts, _, _, GoalPath)
		->
			goal_path_to_string(GoalPath, GoalPathStr),
			stack_layout__lookup_string_in_table(GoalPathStr,
				GoalPathNum, !Info),
			MaybeGoalPath = yes(GoalPathNum)
		;
				% If tracing is enabled, then exactly one of
				% the calls for which this label is a return
				% site would have had a valid context. If none
				% do, then tracing is not enabled, and
				% therefore the goal path of this label will
				% not be accessed.
			MaybeGoalPath = no
		)
	;
		Trace = no,
		Return = no,
		MaybePort = no,
		MaybeIsHidden = no,
		MaybeGoalPath = no
	;
		Trace = yes(_),
		Return = yes(_),
		error("label has both trace and return layout info")
	),
	stack_layout__get_agc_stack_layout(!.Info, AgcStackLayout),
	(
		Return = no,
		set__init(ReturnLiveVarSet),
		map__init(ReturnTypeVarMap)
	;
		Return = yes(return_layout_info(_, ReturnLayout)),
		ReturnLayout = layout_label_info(ReturnLiveVarSet0,
			ReturnTypeVarMap0),
		(
			AgcStackLayout = yes,
			ReturnLiveVarSet = ReturnLiveVarSet0,
			ReturnTypeVarMap = ReturnTypeVarMap0
		;
			AgcStackLayout = no,
			% This set of variables must be for uplevel printing
			% in execution tracing, so we are interested only
			% in (a) variables, not temporaries, (b) only named
			% variables, and (c) only those on the stack, not
			% the return values.
			set__to_sorted_list(ReturnLiveVarSet0,
				ReturnLiveVarList0),
			stack_layout__select_trace_return(
				ReturnLiveVarList0, ReturnTypeVarMap0,
				ReturnLiveVarList, ReturnTypeVarMap),
			set__list_to_set(ReturnLiveVarList, ReturnLiveVarSet)
		)
	),
	(
		Trace = no,
		Resume = no,
		Return = no
	->
		MaybeVarInfo = no,
		LabelVars = label_has_no_var_info
	;
			% XXX ignore differences in insts inside
			% layout_var_infos
		set__union(TraceLiveVarSet, ResumeLiveVarSet, LiveVarSet0),
		set__union(LiveVarSet0, ReturnLiveVarSet, LiveVarSet),
		map__union(set__intersect, TraceTypeVarMap, ResumeTypeVarMap,
			TypeVarMap0),
		map__union(set__intersect, TypeVarMap0, ReturnTypeVarMap,
			TypeVarMap),
		stack_layout__construct_livelval_rvals(LiveVarSet, VarNumMap,
			TypeVarMap, EncodedLength, LiveValRval, NamesRval,
			TypeParamRval, !Info),
		VarInfo = label_var_info(EncodedLength, LiveValRval, NamesRval,
			TypeParamRval),
		MaybeVarInfo = yes(VarInfo),
		LabelVars = label_has_var_info
	),

	(
		Trace = yes(_),
		stack_layout__allocate_label_number(LabelNumber0, !Info),
		% MR_ml_label_exec_count[0] is never written out;
		% it is reserved for cases like this, for labels without
		% events, and for handwritten labels.
		( LabelNumber0 < (1 << 16) ->
			LabelNumber = LabelNumber0
		;
			LabelNumber = 0
		)
	;
		Trace = no,
		LabelNumber = 0
	),
	LayoutData = label_layout_data(ProcLabel, LabelNum, ProcLayoutName,
		MaybePort, MaybeIsHidden, LabelNumber, MaybeGoalPath,
		MaybeVarInfo),
	CData = layout_data(LayoutData),
	LayoutName = label_layout(ProcLabel, LabelNum, LabelVars),
	Label = internal(LabelNum, ProcLabel),
	stack_layout__add_internal_layout_data(CData, Label, LayoutName,
		!Info),
	LabelLayout = {ProcLabel, LabelNum, LabelVars, Internal}.

%---------------------------------------------------------------------------%

:- pred stack_layout__construct_livelval_rvals(set(layout_var_info)::in,
	var_num_map::in, map(tvar, set(layout_locn))::in, int::out,
	rval::out, rval::out, rval::out,
	stack_layout_info::in, stack_layout_info::out) is det.

stack_layout__construct_livelval_rvals(LiveLvalSet, VarNumMap, TVarLocnMap,
		EncodedLength, LiveValRval, NamesRval, TypeParamRval, !Info) :-
	set__to_sorted_list(LiveLvalSet, LiveLvals),
	stack_layout__sort_livevals(LiveLvals, SortedLiveLvals),
	stack_layout__construct_liveval_arrays(SortedLiveLvals, VarNumMap,
		EncodedLength, LiveValRval, NamesRval, !Info),
	StaticCellInfo0 = !.Info ^ static_cell_info,
	stack_layout__construct_tvar_vector(TVarLocnMap,
		TypeParamRval, StaticCellInfo0, StaticCellInfo),
	!:Info = !.Info ^ static_cell_info := StaticCellInfo.

:- pred stack_layout__construct_tvar_vector(map(tvar, set(layout_locn))::in,
	rval::out, static_cell_info::in, static_cell_info::out) is det.

stack_layout__construct_tvar_vector(TVarLocnMap, TypeParamRval,
		!StaticCellInfo) :-
	( map__is_empty(TVarLocnMap) ->
		TypeParamRval = const(int_const(0))
	;
		stack_layout__construct_tvar_rvals(TVarLocnMap, Vector),
		add_static_cell(Vector, DataAddr, !StaticCellInfo),
		TypeParamRval = const(data_addr_const(DataAddr, no))
	).

:- pred stack_layout__construct_tvar_rvals(map(tvar, set(layout_locn))::in,
	assoc_list(rval, llds_type)::out) is det.

stack_layout__construct_tvar_rvals(TVarLocnMap, Vector) :-
	map__to_assoc_list(TVarLocnMap, TVarLocns),
	stack_layout__construct_type_param_locn_vector(TVarLocns, 1,
		TypeParamLocs),
	list__length(TypeParamLocs, TypeParamsLength),
	LengthRval = const(int_const(TypeParamsLength)),
	Vector = [LengthRval - uint_least32 | TypeParamLocs].

%---------------------------------------------------------------------------%

	% Given a list of layout_var_infos and the type variables that occur
	% in them, select only the layout_var_infos that may be required
	% by up-level printing in the trace-based debugger. At the moment
	% the typeinfo list we return may be bigger than necessary, but this
	% does not compromise correctness; we do this to avoid having to
	% scan the types of all the selected layout_var_infos.

:- pred stack_layout__select_trace_return(
	list(layout_var_info)::in, map(tvar, set(layout_locn))::in,
	list(layout_var_info)::out, map(tvar, set(layout_locn))::out) is det.

stack_layout__select_trace_return(Infos, TVars, TraceReturnInfos, TVars) :-
	IsNamedReturnVar = (pred(LocnInfo::in) is semidet :-
		LocnInfo = layout_var_info(Locn, LvalType, _),
		LvalType = var(_, Name, _, _),
		Name \= "",
		( Locn = direct(Lval) ; Locn = indirect(Lval, _)),
		( Lval = stackvar(_) ; Lval = framevar(_) )
	),
	list__filter(IsNamedReturnVar, Infos, TraceReturnInfos).

	% Given a list of layout_var_infos, put the ones that tracing can be
	% interested in (whether at an internal port or for uplevel printing)
	% in a block at the start, and both this block and the remaining
	% block. The division into two blocks can make the job of the
	% debugger somewhat easier, the sorting of the named var block makes
	% the output of the debugger look nicer, and the sorting of the both
	% blocks makes it more likely that different labels' layout structures
	% will have common parts (e.g. name vectors).

:- pred stack_layout__sort_livevals(list(layout_var_info)::in,
	list(layout_var_info)::out) is det.

stack_layout__sort_livevals(OrigInfos, FinalInfos) :-
	IsNamedVar = (pred(LvalInfo::in) is semidet :-
		LvalInfo = layout_var_info(_Lval, LvalType, _),
		LvalType = var(_, Name, _, _),
		Name \= ""
	),
	list__filter(IsNamedVar, OrigInfos, NamedVarInfos0, OtherInfos0),
	CompareVarInfos = (pred(Var1::in, Var2::in, Result::out) is det :-
		Var1 = layout_var_info(Lval1, LiveType1, _),
		Var2 = layout_var_info(Lval2, LiveType2, _),
		stack_layout__get_name_from_live_value_type(LiveType1, Name1),
		stack_layout__get_name_from_live_value_type(LiveType2, Name2),
		compare(NameResult, Name1, Name2),
		( NameResult = (=) ->
			compare(Result, Lval1, Lval2)
		;
			Result = NameResult
		)
	),
	list__sort(CompareVarInfos, NamedVarInfos0, NamedVarInfos),
	list__sort(CompareVarInfos, OtherInfos0, OtherInfos),
	list__append(NamedVarInfos, OtherInfos, FinalInfos).

:- pred stack_layout__get_name_from_live_value_type(live_value_type::in,
	string::out) is det.

stack_layout__get_name_from_live_value_type(LiveType, Name) :-
	( LiveType = var(_, NamePrime, _, _) ->
		Name = NamePrime
	;
		Name = ""
	).

%---------------------------------------------------------------------------%

	% Given a association list of type variables and their locations
	% sorted on the type variables, represent them in an array of
	% location descriptions indexed by the type variable. The next
	% slot to fill is given by the second argument.

:- pred stack_layout__construct_type_param_locn_vector(
	assoc_list(tvar, set(layout_locn))::in,
	int::in, assoc_list(rval, llds_type)::out) is det.

stack_layout__construct_type_param_locn_vector([], _, []).
stack_layout__construct_type_param_locn_vector([TVar - Locns | TVarLocns],
		CurSlot, Vector) :-
	term__var_to_int(TVar, TVarNum),
	NextSlot = CurSlot + 1,
	( TVarNum = CurSlot ->
		( set__remove_least(Locns, LeastLocn, _) ->
			Locn = LeastLocn
		;
			error("tvar has empty set of locations")
		),
		stack_layout__represent_locn_as_int_rval(Locn, Rval),
		stack_layout__construct_type_param_locn_vector(TVarLocns,
			NextSlot, VectorTail),
		Vector = [Rval - uint_least32 | VectorTail]
	; TVarNum > CurSlot ->
		stack_layout__construct_type_param_locn_vector(
			[TVar - Locns | TVarLocns], NextSlot, VectorTail),
			% This slot will never be referred to.
		Vector = [const(int_const(0)) - uint_least32 | VectorTail]
	;
		error("unsorted tvars in construct_type_param_locn_vector")
	).

%---------------------------------------------------------------------------%

:- type liveval_array_info
	--->	live_array_info(
			rval,	% Rval describing the location of a live value.
				% Always of llds type uint_least8 if the cell
				% is in the byte array, and uint_least32 if it
				% is in the int array.
			rval,	% Rval describing the type of a live value.
			llds_type, % The llds type of the rval describing the
				% type.
			rval	% Rval describing the variable number of a
				% live value. Always of llds type uint_least16.
				% Contains zero if the live value is not
				% a variable. Contains the hightest possible
				% uint_least16 value if the variable number
				% does not fit in 16 bits.
		).

	% Construct a vector of (locn, live_value_type) pairs,
	% and a corresponding vector of variable names.

:- pred stack_layout__construct_liveval_arrays(list(layout_var_info)::in,
	var_num_map::in, int::out, rval::out, rval::out,
	stack_layout_info::in, stack_layout_info::out) is det.

stack_layout__construct_liveval_arrays(VarInfos, VarNumMap, EncodedLength,
		TypeLocnVector, NumVector, !Info) :-
	int__pow(2, stack_layout__short_count_bits, BytesLimit),
	stack_layout__construct_liveval_array_infos(VarInfos, VarNumMap,
		0, BytesLimit, IntArrayInfo, ByteArrayInfo, !Info),

	list__length(IntArrayInfo, IntArrayLength),
	list__length(ByteArrayInfo, ByteArrayLength),
	list__append(IntArrayInfo, ByteArrayInfo, AllArrayInfo),

	EncodedLength = IntArrayLength << stack_layout__short_count_bits
		+ ByteArrayLength,

	SelectLocns = (pred(ArrayInfo::in, LocnRval::out) is det :-
		ArrayInfo = live_array_info(LocnRval, _, _, _)
	),
	SelectTypes = (pred(ArrayInfo::in, TypeRval - TypeType::out) is det :-
		ArrayInfo = live_array_info(_, TypeRval, TypeType, _)
	),
	AddRevNums = (pred(ArrayInfo::in, NumRvals0::in, NumRvals::out)
			is det :-
		ArrayInfo = live_array_info(_, _, _, NumRval),
		NumRvals = [NumRval | NumRvals0]
	),

	list__map(SelectTypes, AllArrayInfo, AllTypeRvalsTypes),
	list__map(SelectLocns, IntArrayInfo, IntLocns),
	list__map(associate_type(uint_least32), IntLocns, IntLocnsTypes),
	list__map(SelectLocns, ByteArrayInfo, ByteLocns),
	list__map(associate_type(uint_least8), ByteLocns, ByteLocnsTypes),
	list__append(IntLocnsTypes, ByteLocnsTypes, AllLocnsTypes),
	list__append(AllTypeRvalsTypes, AllLocnsTypes,
		TypeLocnVectorRvalsTypes),
	stack_layout__get_static_cell_info(!.Info, StaticCellInfo0),
	add_static_cell(TypeLocnVectorRvalsTypes, TypeLocnVectorAddr,
		StaticCellInfo0, StaticCellInfo1),
	TypeLocnVector = const(data_addr_const(TypeLocnVectorAddr, no)),
	stack_layout__set_static_cell_info(StaticCellInfo1, !Info),

	stack_layout__get_trace_stack_layout(!.Info, TraceStackLayout),
	(
		TraceStackLayout = yes,
		list__foldl(AddRevNums, AllArrayInfo,
			[], RevVarNumRvals),
		list__reverse(RevVarNumRvals, VarNumRvals),
		list__map(associate_type(uint_least16), VarNumRvals,
			VarNumRvalsTypes),
		stack_layout__get_static_cell_info(!.Info, StaticCellInfo2),
		add_static_cell(VarNumRvalsTypes, NumVectorAddr,
			StaticCellInfo2, StaticCellInfo),
		stack_layout__set_static_cell_info(StaticCellInfo, !Info),
		NumVector = const(data_addr_const(NumVectorAddr, no))
	;
		TraceStackLayout = no,
		NumVector = const(int_const(0))
	).

:- pred associate_type(llds_type::in, rval::in, pair(rval, llds_type)::out)
	is det.

associate_type(LldsType, Rval, Rval - LldsType).

:- pred stack_layout__construct_liveval_array_infos(list(layout_var_info)::in,
	var_num_map::in, int::in, int::in,
	list(liveval_array_info)::out, list(liveval_array_info)::out,
	stack_layout_info::in, stack_layout_info::out) is det.

stack_layout__construct_liveval_array_infos([], _, _, _, [], [], !Info).
stack_layout__construct_liveval_array_infos([VarInfo | VarInfos], VarNumMap,
		BytesSoFar, BytesLimit, IntVars, ByteVars, !Info) :-
	VarInfo = layout_var_info(Locn, LiveValueType, _),
	stack_layout__represent_live_value_type(LiveValueType, TypeRval,
		TypeRvalType, !Info),
	stack_layout__construct_liveval_num_rval(VarNumMap, VarInfo,
		VarNumRval, !Info),
	(
		LiveValueType = var(_, _, Type, _),
		is_dummy_argument_type(Type),
		% We want to preserve I/O states in registers
		\+ (
			Locn = direct(reg(_, _))
		)
	->
		error("construct_liveval_array_infos: " ++
			"unexpected reference to dummy value")
	;
		BytesSoFar < BytesLimit,
		stack_layout__represent_locn_as_byte(Locn, LocnByteRval)
	->
		Var = live_array_info(LocnByteRval, TypeRval, TypeRvalType,
			VarNumRval),
		stack_layout__construct_liveval_array_infos(VarInfos,
			VarNumMap, BytesSoFar + 1, BytesLimit,
			IntVars, ByteVars0, !Info),
		ByteVars = [Var | ByteVars0]
	;
		stack_layout__represent_locn_as_int_rval(Locn, LocnRval),
		Var = live_array_info(LocnRval, TypeRval, TypeRvalType,
			VarNumRval),
		stack_layout__construct_liveval_array_infos(VarInfos,
			VarNumMap, BytesSoFar, BytesLimit,
			IntVars0, ByteVars, !Info),
		IntVars = [Var | IntVars0]
	).

:- pred stack_layout__construct_liveval_num_rval(var_num_map::in,
	layout_var_info::in, rval::out,
	stack_layout_info::in, stack_layout_info::out) is det.

stack_layout__construct_liveval_num_rval(VarNumMap,
		layout_var_info(_, LiveValueType, _), VarNumRval, !Info) :-
	( LiveValueType = var(Var, _, _, _) ->
		stack_layout__convert_var_to_int(VarNumMap, Var, VarNum),
		VarNumRval = const(int_const(VarNum))
	;
		VarNumRval = const(int_const(0))
	).

:- pred stack_layout__convert_var_to_int(var_num_map::in, prog_var::in,
	int::out) is det.

stack_layout__convert_var_to_int(VarNumMap, Var, VarNum) :-
	map__lookup(VarNumMap, Var, VarNum0 - _),
		% The variable number has to fit into two bytes.
		% We reserve the largest such number (Limit)
		% to mean that the variable number is too large
		% to be represented. This ought not to happen,
		% since compilation would be glacial at best
		% for procedures with that many variables.
	Limit = (1 << (2 * stack_layout__byte_bits)) - 1,
	int__min(VarNum0, Limit, VarNum).

%---------------------------------------------------------------------------%

	% The representation we build here should be kept in sync
	% with runtime/mercury_ho_call.h, which contains macros to access
	% the data structures we build here.

stack_layout__construct_closure_layout(CallerProcLabel, SeqNo,
		ClosureLayoutInfo, ClosureProcLabel, ModuleName,
		FileName, LineNumber, GoalPath, !StaticCellInfo,
		RvalsTypes, Data) :-
	DataAddr = layout_addr(
		closure_proc_id(CallerProcLabel, SeqNo, ClosureProcLabel)),
	Data = layout_data(closure_proc_id_data(CallerProcLabel, SeqNo,
		ClosureProcLabel, ModuleName, FileName, LineNumber, GoalPath)),
	ProcIdRvalType = const(data_addr_const(DataAddr, no)) - data_ptr,
	ClosureLayoutInfo = closure_layout_info(ClosureArgs, TVarLocnMap),
	stack_layout__construct_closure_arg_rvals(ClosureArgs,
		ClosureArgRvalsTypes, !StaticCellInfo),
	stack_layout__construct_tvar_vector(TVarLocnMap, TVarVectorRval,
		!StaticCellInfo),
	RvalsTypes = [ProcIdRvalType, TVarVectorRval - data_ptr |
		ClosureArgRvalsTypes].

:- pred stack_layout__construct_closure_arg_rvals(list(closure_arg_info)::in,
	assoc_list(rval, llds_type)::out,
	static_cell_info::in, static_cell_info::out) is det.

stack_layout__construct_closure_arg_rvals(ClosureArgs, ClosureArgRvalsTypes,
		!StaticCellInfo) :-
	list__map_foldl(stack_layout__construct_closure_arg_rval,
		ClosureArgs, ArgRvalsTypes, !StaticCellInfo),
	list__length(ArgRvalsTypes, Length),
	ClosureArgRvalsTypes =
		[const(int_const(Length)) - integer | ArgRvalsTypes].

:- pred stack_layout__construct_closure_arg_rval(closure_arg_info::in,
	pair(rval, llds_type)::out,
	static_cell_info::in, static_cell_info::out) is det.

stack_layout__construct_closure_arg_rval(ClosureArg, ArgRval - ArgRvalType,
		!StaticCellInfo) :-
	ClosureArg = closure_arg_info(Type, _Inst),
		% For a stack layout, we can treat all type variables as
		% universally quantified. This is not the argument of a
		% constructor, so we do not need to distinguish between type
		% variables that are and aren't in scope; we can take the
		% variable number directly from the procedure's tvar set.
	ExistQTvars = [],
	NumUnivQTvars = -1,
	ll_pseudo_type_info__construct_typed_llds_pseudo_type_info(Type,
		NumUnivQTvars, ExistQTvars, !StaticCellInfo,
		ArgRval, ArgRvalType).

%---------------------------------------------------------------------------%

:- pred stack_layout__make_table_data(rtti_proc_label::in,
	proc_layout_kind::in, proc_table_info::in, layout_data::out,
	static_cell_info::in, static_cell_info::out) is det.

stack_layout__make_table_data(RttiProcLabel, Kind, TableInfo, TableData,
		!StaticCellInfo) :-
	(
		TableInfo = table_io_decl_info(TableArgInfo),
		stack_layout__convert_table_arg_info(TableArgInfo,
			NumPTIs, PTIVectorRval, TVarVectorRval,
			!StaticCellInfo),
		TableData = table_io_decl_data(RttiProcLabel, Kind,
			NumPTIs, PTIVectorRval, TVarVectorRval)
	;
		TableInfo = table_gen_info(NumInputs, NumOutputs, Steps,
			TableArgInfo),
		stack_layout__convert_table_arg_info(TableArgInfo,
			NumPTIs, PTIVectorRval, TVarVectorRval,
			!StaticCellInfo),
		NumArgs = NumInputs + NumOutputs,
		require(unify(NumArgs, NumPTIs),
			"stack_layout__make_table_data: args mismatch"),
		TableData = table_gen_data(RttiProcLabel,
			NumInputs, NumOutputs, Steps,
			PTIVectorRval, TVarVectorRval)
	).

:- pred stack_layout__convert_table_arg_info(table_arg_infos::in,
	int::out, rval::out, rval::out,
	static_cell_info::in, static_cell_info::out) is det.

stack_layout__convert_table_arg_info(TableArgInfos, NumPTIs,
		PTIVectorRval, TVarVectorRval, !StaticCellInfo) :-
	TableArgInfos = table_arg_infos(Args, TVarSlotMap),
	list__length(Args, NumPTIs),
	list__map_foldl(stack_layout__construct_table_arg_pti_rval,
		Args, PTIRvalsTypes, !StaticCellInfo),
	add_static_cell(PTIRvalsTypes, PTIVectorAddr, !StaticCellInfo),
	PTIVectorRval = const(data_addr_const(PTIVectorAddr, no)),
	map__map_values(stack_layout__convert_slot_to_locn_map,
		TVarSlotMap, TVarLocnMap),
	stack_layout__construct_tvar_vector(TVarLocnMap, TVarVectorRval,
		!StaticCellInfo).

:- pred stack_layout__convert_slot_to_locn_map(tvar::in, table_locn::in,
	set(layout_locn)::out) is det.

stack_layout__convert_slot_to_locn_map(_TVar, SlotLocn, LvalLocns) :-
	(
		SlotLocn = direct(SlotNum),
		LvalLocn = direct(reg(r, SlotNum))
	;
		SlotLocn = indirect(SlotNum, Offset),
		LvalLocn = indirect(reg(r, SlotNum), Offset)
	),
	LvalLocns = set__make_singleton_set(LvalLocn).

:- pred stack_layout__construct_table_arg_pti_rval(
	table_arg_info::in, pair(rval, llds_type)::out,
	static_cell_info::in, static_cell_info::out) is det.

stack_layout__construct_table_arg_pti_rval(ClosureArg,
		ArgRval - ArgRvalType, !StaticCellInfo) :-
	ClosureArg = table_arg_info(_, _, Type),
	ExistQTvars = [],
	NumUnivQTvars = -1,
	ll_pseudo_type_info__construct_typed_llds_pseudo_type_info(Type,
		NumUnivQTvars, ExistQTvars, !StaticCellInfo,
		ArgRval, ArgRvalType).

%---------------------------------------------------------------------------%

	% Construct a representation of the type of a value.
	%
	% For values representing variables, this will be a pseudo_type_info
	% describing the type of the variable.
	%
	% For the kinds of values used internally by the compiler,
	% this will be a pointer to a specific type_ctor_info (acting as a
	% type_info) defined by hand in builtin.m to stand for values of
	% each such kind; one for succips, one for hps, etc.

:- pred stack_layout__represent_live_value_type(live_value_type::in, rval::out,
	llds_type::out, stack_layout_info::in, stack_layout_info::out) is det.

stack_layout__represent_live_value_type(succip, Rval, data_ptr, !Info) :-
	stack_layout__represent_special_live_value_type("succip", Rval).
stack_layout__represent_live_value_type(hp, Rval, data_ptr, !Info) :-
	stack_layout__represent_special_live_value_type("hp", Rval).
stack_layout__represent_live_value_type(curfr, Rval, data_ptr, !Info) :-
	stack_layout__represent_special_live_value_type("curfr", Rval).
stack_layout__represent_live_value_type(maxfr, Rval, data_ptr, !Info) :-
	stack_layout__represent_special_live_value_type("maxfr", Rval).
stack_layout__represent_live_value_type(redofr, Rval, data_ptr, !Info) :-
	stack_layout__represent_special_live_value_type("redofr", Rval).
stack_layout__represent_live_value_type(redoip, Rval, data_ptr, !Info) :-
	stack_layout__represent_special_live_value_type("redoip", Rval).
stack_layout__represent_live_value_type(trail_ptr, Rval, data_ptr, !Info) :-
	stack_layout__represent_special_live_value_type("trail_ptr", Rval).
stack_layout__represent_live_value_type(ticket, Rval, data_ptr, !Info) :-
	stack_layout__represent_special_live_value_type("ticket", Rval).
stack_layout__represent_live_value_type(unwanted, Rval, data_ptr, !Info) :-
	stack_layout__represent_special_live_value_type("unwanted", Rval).
stack_layout__represent_live_value_type(var(_, _, Type, _), Rval, LldsType,
		!Info) :-
		% For a stack layout, we can treat all type variables as
		% universally quantified. This is not the argument of a
		% constructor, so we do not need to distinguish between type
		% variables that are and aren't in scope; we can take the
		% variable number directly from the procedure's tvar set.
	ExistQTvars = [],
	NumUnivQTvars = -1,
	stack_layout__get_static_cell_info(!.Info, StaticCellInfo0),
	ll_pseudo_type_info__construct_typed_llds_pseudo_type_info(Type,
		NumUnivQTvars, ExistQTvars, StaticCellInfo0, StaticCellInfo,
		Rval, LldsType),
	stack_layout__set_static_cell_info(StaticCellInfo, !Info).

:- pred stack_layout__represent_special_live_value_type(string::in, rval::out)
	is det.

stack_layout__represent_special_live_value_type(SpecialTypeName, Rval) :-
	RttiTypeCtor = rtti_type_ctor(unqualified(""), SpecialTypeName, 0),
	DataAddr = rtti_addr(ctor_rtti_id(RttiTypeCtor, type_ctor_info)),
	Rval = const(data_addr_const(DataAddr, no)).

%---------------------------------------------------------------------------%

	% Construct a representation of a variable location as a 32-bit
	% integer.
	%
	% Most of the time, a layout specifies a location as an lval.
	% However, a type_info variable may be hidden inside a typeclass_info,
	% In this case, accessing the type_info requires indirection.
	% The address of the typeclass_info is given as an lval, and
	% the location of the typeinfo within the typeclass_info as an index;
	% private_builtin:type_info_from_typeclass_info interprets the index.
	%
	% This one level of indirection is sufficient, since type_infos
	% cannot be nested inside typeclass_infos any deeper than this.
	% A more general representation that would allow more indirection
	% would be much harder to fit into one machine word.

:- pred stack_layout__represent_locn_as_int_rval(layout_locn::in, rval::out)
	is det.

stack_layout__represent_locn_as_int_rval(Locn, Rval) :-
	stack_layout__represent_locn_as_int(Locn, Word),
	Rval = const(int_const(Word)).

stack_layout__represent_locn_as_int(direct(Lval), Word) :-
	stack_layout__represent_lval(Lval, Word).
stack_layout__represent_locn_as_int(indirect(Lval, Offset), Word) :-
	stack_layout__represent_lval(Lval, BaseWord),
	require((1 << stack_layout__long_lval_offset_bits) > Offset,
	"stack_layout__represent_locn: offset too large to be represented"),
	BaseAndOffset is (BaseWord << stack_layout__long_lval_offset_bits)
		+ Offset,
	stack_layout__make_tagged_word(lval_indirect, BaseAndOffset, Word).

	% Construct a four byte representation of an lval.

:- pred stack_layout__represent_lval(lval::in, int::out) is det.

stack_layout__represent_lval(reg(r, Num), Word) :-
	stack_layout__make_tagged_word(lval_r_reg, Num, Word).
stack_layout__represent_lval(reg(f, Num), Word) :-
	stack_layout__make_tagged_word(lval_f_reg, Num, Word).
stack_layout__represent_lval(stackvar(Num), Word) :-
	require(Num > 0, "stack_layout__represent_lval: bad stackvar"),
	stack_layout__make_tagged_word(lval_stackvar, Num, Word).
stack_layout__represent_lval(framevar(Num), Word) :-
	require(Num > 0, "stack_layout__represent_lval: bad framevar"),
	stack_layout__make_tagged_word(lval_framevar, Num, Word).
stack_layout__represent_lval(succip, Word) :-
	stack_layout__make_tagged_word(lval_succip, 0, Word).
stack_layout__represent_lval(maxfr, Word) :-
	stack_layout__make_tagged_word(lval_maxfr, 0, Word).
stack_layout__represent_lval(curfr, Word) :-
	stack_layout__make_tagged_word(lval_curfr, 0, Word).
stack_layout__represent_lval(hp, Word) :-
	stack_layout__make_tagged_word(lval_hp, 0, Word).
stack_layout__represent_lval(sp, Word) :-
	stack_layout__make_tagged_word(lval_sp, 0, Word).

stack_layout__represent_lval(temp(_, _), _) :-
	error("stack_layout: continuation live value stored in temp register").

stack_layout__represent_lval(succip(_), _) :-
	error("stack_layout: continuation live value stored in fixed slot").
stack_layout__represent_lval(redoip(_), _) :-
	error("stack_layout: continuation live value stored in fixed slot").
stack_layout__represent_lval(redofr(_), _) :-
	error("stack_layout: continuation live value stored in fixed slot").
stack_layout__represent_lval(succfr(_), _) :-
	error("stack_layout: continuation live value stored in fixed slot").
stack_layout__represent_lval(prevfr(_), _) :-
	error("stack_layout: continuation live value stored in fixed slot").

stack_layout__represent_lval(field(_, _, _), _) :-
	error("stack_layout: continuation live value stored in field").
stack_layout__represent_lval(mem_ref(_), _) :-
	error("stack_layout: continuation live value stored in mem_ref").
stack_layout__represent_lval(lvar(_), _) :-
	error("stack_layout: continuation live value stored in lvar").

	% Some things in this module are encoded using a low tag.
	% This is not done using the normal compiler mkword, but by
	% doing the bit shifting here.
	%
	% This allows us to use more than the usual 2 or 3 bits, but
	% we have to use low tags and cannot tag pointers this way.

:- pred stack_layout__make_tagged_word(locn_type::in, int::in, int::out) is det.

stack_layout__make_tagged_word(Locn, Value, TaggedValue) :-
	stack_layout__locn_type_code(Locn, Tag),
	TaggedValue is (Value << stack_layout__long_lval_tag_bits) + Tag.

:- type locn_type
	--->	lval_r_reg
	;	lval_f_reg
	;	lval_stackvar
	;	lval_framevar
	;	lval_succip
	;	lval_maxfr
	;	lval_curfr
	;	lval_hp
	;	lval_sp
	;	lval_indirect.

:- pred stack_layout__locn_type_code(locn_type::in, int::out) is det.

stack_layout__locn_type_code(lval_r_reg,    0).
stack_layout__locn_type_code(lval_f_reg,    1).
stack_layout__locn_type_code(lval_stackvar, 2).
stack_layout__locn_type_code(lval_framevar, 3).
stack_layout__locn_type_code(lval_succip,   4).
stack_layout__locn_type_code(lval_maxfr,    5).
stack_layout__locn_type_code(lval_curfr,    6).
stack_layout__locn_type_code(lval_hp,       7).
stack_layout__locn_type_code(lval_sp,       8).
stack_layout__locn_type_code(lval_indirect, 9).

:- func stack_layout__long_lval_tag_bits = int.

% This number of tag bits must be able to encode all values of
% stack_layout__locn_type_code.

stack_layout__long_lval_tag_bits = 4.

% This number of tag bits must be able to encode the largest offset
% of a type_info within a typeclass_info.

:- func stack_layout__long_lval_offset_bits = int.

stack_layout__long_lval_offset_bits = 6.

%---------------------------------------------------------------------------%

	% Construct a representation of a variable location as a byte,
	% if this is possible.

:- pred stack_layout__represent_locn_as_byte(layout_locn::in, rval::out)
	is semidet.

stack_layout__represent_locn_as_byte(LayoutLocn, Rval) :-
	LayoutLocn = direct(Lval),
	stack_layout__represent_lval_as_byte(Lval, Byte),
	0 =< Byte,
	Byte < 256,
	Rval = const(int_const(Byte)).

	% Construct a representation of an lval in a byte, if possible.

:- pred stack_layout__represent_lval_as_byte(lval::in, int::out) is semidet.

stack_layout__represent_lval_as_byte(reg(r, Num), Byte) :-
	require(Num > 0, "stack_layout__represent_lval_as_byte: bad reg"),
	stack_layout__make_tagged_byte(0, Num, Byte).
stack_layout__represent_lval_as_byte(stackvar(Num), Byte) :-
	require(Num > 0, "stack_layout__represent_lval_as_byte: bad stackvar"),
	stack_layout__make_tagged_byte(1, Num, Byte).
stack_layout__represent_lval_as_byte(framevar(Num), Byte) :-
	require(Num > 0, "stack_layout__represent_lval_as_byte: bad framevar"),
	stack_layout__make_tagged_byte(2, Num, Byte).
stack_layout__represent_lval_as_byte(succip, Byte) :-
	stack_layout__locn_type_code(lval_succip, Val),
	stack_layout__make_tagged_byte(3, Val, Byte).
stack_layout__represent_lval_as_byte(maxfr, Byte) :-
	stack_layout__locn_type_code(lval_maxfr, Val),
	stack_layout__make_tagged_byte(3, Val, Byte).
stack_layout__represent_lval_as_byte(curfr, Byte) :-
	stack_layout__locn_type_code(lval_curfr, Val),
	stack_layout__make_tagged_byte(3, Val, Byte).
stack_layout__represent_lval_as_byte(hp, Byte) :-
	stack_layout__locn_type_code(lval_hp, Val),
	stack_layout__make_tagged_byte(3, Val, Byte).
stack_layout__represent_lval_as_byte(sp, Byte) :-
	stack_layout__locn_type_code(lval_sp, Val),
	stack_layout__make_tagged_byte(3, Val, Byte).

:- pred stack_layout__make_tagged_byte(int::in, int::in, int::out) is det.

stack_layout__make_tagged_byte(Tag, Value, TaggedValue) :-
	TaggedValue is unchecked_left_shift(Value,
		stack_layout__short_lval_tag_bits) + Tag.

:- func stack_layout__short_lval_tag_bits = int.

stack_layout__short_lval_tag_bits = 2.

:- func stack_layout__short_count_bits = int.

stack_layout__short_count_bits = 10.

:- func stack_layout__byte_bits = int.

stack_layout__byte_bits = 8.

%---------------------------------------------------------------------------%

stack_layout__represent_determinism_rval(Detism,
		const(int_const(code_model__represent_determinism(Detism)))).

%---------------------------------------------------------------------------%

	% Access to the stack_layout data structure.

	% The per-sourcefile label table maps line numbers to the list of
	% labels that correspond to that line. Each label is accompanied
	% by a flag that says whether the label is the return site of a call
	% or not, and if it is, whether the called procedure is known.

:- type is_label_return
	--->	known_callee(label)
	;	unknown_callee
	;	not_a_return.

:- type line_no_info == pair(layout_name, is_label_return).

:- type label_table == map(int, list(line_no_info)).

:- type stack_layout_info 	--->
	stack_layout_info(
		module_info		:: module_info,
		agc_stack_layout	:: bool, % generate agc info?
		trace_stack_layout	:: bool, % generate tracing info?
		procid_stack_layout	:: bool, % generate proc id info?
		static_code_addresses	:: bool, % have static code addresses?
		label_counter		:: counter,
		table_infos		:: list(comp_gen_c_data),
		proc_layouts		:: list(comp_gen_c_data),
		internal_layouts	:: list(comp_gen_c_data),
		label_set		:: map(label, data_addr),
					   % The set of labels (both entry
					   % and internal) with layouts.
		proc_layout_name_list	:: list(layout_name),
					   % The list of proc_layouts in
					   % the module.
		string_table		:: string_table,
		label_tables		:: map(string, label_table),
					   % Maps each filename that
					   % contributes labels to this module
					   % to a table describing those
					   % labels.
		static_cell_info	:: static_cell_info
	).

:- pred stack_layout__get_module_info(stack_layout_info::in,
	module_info::out) is det.
:- pred stack_layout__get_agc_stack_layout(stack_layout_info::in,
	bool::out) is det.
:- pred stack_layout__get_trace_stack_layout(stack_layout_info::in,
	bool::out) is det.
:- pred stack_layout__get_procid_stack_layout(stack_layout_info::in,
	bool::out) is det.
:- pred stack_layout__get_static_code_addresses(stack_layout_info::in,
	bool::out) is det.
:- pred stack_layout__get_table_infos(stack_layout_info::in,
	list(comp_gen_c_data)::out) is det.
:- pred stack_layout__get_proc_layout_data(stack_layout_info::in,
	list(comp_gen_c_data)::out) is det.
:- pred stack_layout__get_internal_layout_data(stack_layout_info::in,
	list(comp_gen_c_data)::out) is det.
:- pred stack_layout__get_label_set(stack_layout_info::in,
	map(label, data_addr)::out) is det.
:- pred stack_layout__get_string_table(stack_layout_info::in,
	string_table::out) is det.
:- pred stack_layout__get_label_tables(stack_layout_info::in,
	map(string, label_table)::out) is det.
:- pred stack_layout__get_static_cell_info(stack_layout_info::in,
	static_cell_info::out) is det.

stack_layout__get_module_info(LI, LI ^ module_info).
stack_layout__get_agc_stack_layout(LI, LI ^ agc_stack_layout).
stack_layout__get_trace_stack_layout(LI, LI ^ trace_stack_layout).
stack_layout__get_procid_stack_layout(LI, LI ^ procid_stack_layout).
stack_layout__get_static_code_addresses(LI, LI ^ static_code_addresses).
stack_layout__get_table_infos(LI, LI ^ table_infos).
stack_layout__get_proc_layout_data(LI, LI ^ proc_layouts).
stack_layout__get_internal_layout_data(LI, LI ^ internal_layouts).
stack_layout__get_label_set(LI, LI ^ label_set).
stack_layout__get_string_table(LI, LI ^ string_table).
stack_layout__get_label_tables(LI, LI ^ label_tables).
stack_layout__get_static_cell_info(LI, LI ^ static_cell_info).

:- pred stack_layout__allocate_label_number(int::out,
	stack_layout_info::in, stack_layout_info::out) is det.

stack_layout__allocate_label_number(LabelNum, !LI) :-
	Counter0 = !.LI ^ label_counter,
	counter__allocate(LabelNum, Counter0, Counter),
	!:LI = !.LI ^ label_counter := Counter.

:- pred stack_layout__add_table_data(layout_data::in,
	stack_layout_info::in, stack_layout_info::out) is det.

stack_layout__add_table_data(TableIoDeclData, !LI) :-
	TableIoDecls0 = !.LI ^ table_infos,
	TableIoDecls = [layout_data(TableIoDeclData) | TableIoDecls0],
	!:LI = !.LI ^ table_infos := TableIoDecls.

:- pred stack_layout__add_proc_layout_data(comp_gen_c_data::in,
	layout_name::in, label::in,
	stack_layout_info::in, stack_layout_info::out) is det.

stack_layout__add_proc_layout_data(ProcLayout, ProcLayoutName, Label, !LI) :-
	ProcLayouts0 = !.LI ^ proc_layouts,
	ProcLayouts = [ProcLayout | ProcLayouts0],
	LabelSet0 = !.LI ^ label_set,
	map__det_insert(LabelSet0, Label, layout_addr(ProcLayoutName),
		LabelSet),
	ProcLayoutNames0 = !.LI ^ proc_layout_name_list,
	ProcLayoutNames = [ProcLayoutName | ProcLayoutNames0],
	!:LI = (((!.LI ^ proc_layouts := ProcLayouts)
		^ label_set := LabelSet)
		^ proc_layout_name_list := ProcLayoutNames).

:- pred stack_layout__add_internal_layout_data(comp_gen_c_data::in,
	label::in, layout_name::in, stack_layout_info::in,
	stack_layout_info::out) is det.

stack_layout__add_internal_layout_data(InternalLayout, Label, LayoutName,
		!LI) :-
	InternalLayouts0 = !.LI ^ internal_layouts,
	InternalLayouts = [InternalLayout | InternalLayouts0],
	LabelSet0 = !.LI ^ label_set,
	map__det_insert(LabelSet0, Label, layout_addr(LayoutName), LabelSet),
	!:LI = ((!.LI ^ internal_layouts := InternalLayouts)
		^ label_set := LabelSet).

:- pred stack_layout__set_string_table(string_table::in,
	stack_layout_info::in, stack_layout_info::out) is det.

:- pred stack_layout__set_label_tables(map(string, label_table)::in,
	stack_layout_info::in, stack_layout_info::out) is det.

:- pred stack_layout__set_static_cell_info(static_cell_info::in,
	stack_layout_info::in, stack_layout_info::out) is det.

stack_layout__set_string_table(ST, LI, LI ^ string_table := ST).
stack_layout__set_label_tables(LT, LI, LI ^ label_tables := LT).
stack_layout__set_static_cell_info(SCI, LI, LI ^ static_cell_info := SCI).

%---------------------------------------------------------------------------%

	% Access to the string_table data structure.

:- type string_table 	--->
	string_table(
		map(string, int),	% Maps strings to their offsets.
		list(string),		% List of strings so far,
					% in reverse order.
		int			% Next available offset
	).

:- pred stack_layout__lookup_string_in_table(string::in, int::out,
	stack_layout_info::in, stack_layout_info::out) is det.

stack_layout__lookup_string_in_table(String, Offset, !Info) :-
	StringTable0 = !.Info ^ string_table,
	StringTable0 = string_table(TableMap0, TableList0, TableOffset0),
	( map__search(TableMap0, String, OldOffset) ->
		Offset = OldOffset
	;
		string__length(String, Length),
		TableOffset = TableOffset0 + Length + 1,
		% We use a 32 bit unsigned integer to represent the offset.
		% Computing that limit exactly without getting an overflow
		% or using unportable code isn't trivial. The code below
		% is overly conservative, requiring the offset to be
		% representable in only 30 bits. The over-conservatism
		% should not be an issue; the machine will run out of
		% virtual memory before the test below fails, for the
		% next several years anyway. (Compiling a module that has
		% a 1 Gb string table will require several tens of Gb
		% of other compiler structures.)
		TableOffset < (1 << ((4 * stack_layout__byte_bits) - 2))
	->
		Offset = TableOffset0,
		map__det_insert(TableMap0, String, TableOffset0,
			TableMap),
		TableList = [String | TableList0],
		StringTable = string_table(TableMap, TableList, TableOffset),
		stack_layout__set_string_table(StringTable, !Info)
	;
		% Says that the name of the variable is "TOO_MANY_VARIABLES".
		Offset = 1
	).
