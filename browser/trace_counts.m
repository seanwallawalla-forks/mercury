%-----------------------------------------------------------------------------%
% Copyright (C) 2005 The University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%-----------------------------------------------------------------------------%
%
% File: trace_counts.m.
%
% Author: wangp.
%
% This module defines a predicate to read in the execution trace summaries
% generated by programs compiled using the compiler's tracing options.

%-----------------------------------------------------------------------------%

:- module mdbcomp__trace_counts.

:- interface.

:- import_module mdbcomp__prim_data.
:- import_module mdbcomp__program_representation.

:- import_module io, map.

:- type trace_counts		== map(proc_label, proc_trace_counts).

:- type proc_trace_counts	== map(path_port, int).

:- type path_port
	--->	port_only(trace_port)
	;	path_only(goal_path)
	;	port_and_path(trace_port, goal_path).

:- type read_trace_counts_result
	--->	ok(trace_counts)
	;	error_message(string)
	;	io_error(io__error).

:- pred read_trace_counts(string::in, read_trace_counts_result::out,
	io::di, io::uo) is det.

%-----------------------------------------------------------------------------%

:- implementation.

:- import_module char, exception, int, io, lexer, list, require, std_util.
:- import_module string, svmap.

read_trace_counts(FileName, ReadResult, !IO) :-
	io__open_input(FileName, Result, !IO),
	(
		Result = ok(FileStream),
		io__set_input_stream(FileStream, OldInputStream, !IO),
		promise_only_solution_io(read_trace_counts_2, ReadResult,
			!IO),
		io__set_input_stream(OldInputStream, _, !IO),
		io__close_input(FileStream, !IO)
	;
		Result = error(IOError),
		ReadResult = io_error(IOError)
	).

:- pred read_trace_counts_2(read_trace_counts_result::out, io::di, io::uo)
	is cc_multi.

read_trace_counts_2(ReadResult, !IO) :-
	try_io(read_trace_counts_3(map__init), Result, !IO),
	(
		Result = succeeded(TraceCounts),
		ReadResult = ok(TraceCounts)
	;
		Result = exception(Exception),
		( Exception = univ(IOError) ->
			ReadResult = io_error(IOError)
		; Exception = univ(Message) ->
			ReadResult = error_message(Message)
		;
			error("read_trace_counts_2: unexpected exception type")
		)
	;
		Result = failed,
		error("read_trace_counts_2: IO failure")
	).

:- pred read_trace_counts_3(trace_counts::in, trace_counts::out,
	io::di, io::uo) is det.

read_trace_counts_3(!TraceCounts, !IO) :-
	io__get_line_number(LineNum, !IO),
	io__read_line_as_string(Result, !IO),
	(
		Result = ok(Line),
		read_proc_trace_counts(LineNum, Line, !TraceCounts, !IO)
	;
		Result = eof
	;
		Result = error(Error),
		throw(Error)
	).

:- pred read_proc_trace_counts(int::in, string::in, trace_counts::in,
	trace_counts::out, io::di, io::uo) is det.

read_proc_trace_counts(HeaderLineNum, HeaderLine, !TraceCounts, !IO) :-
	lexer__string_get_token_list(HeaderLine, string__length(HeaderLine),
		TokenList, posn(HeaderLineNum, 1, 0), _),
	(if
		TokenList =
			token_cons(name("proc"), _,
			token_cons(name(PredOrFuncStr), _,
			token_cons(name(ModuleStr), _,
			token_cons(name(Name), _,
			token_cons(integer(Arity), _,
			token_cons(integer(Mode), _,
			token_nil)))))),
		string_to_pred_or_func(PredOrFuncStr, PredOrFunc)
	then
		string_to_sym_name(ModuleStr, ".", ModuleName),
		% At the moment runtime/mercury_trace_base.c doesn't
		% write out data for 'special' procedures.
		ProcLabel = proc(ModuleName, PredOrFunc, ModuleName, Name,
				Arity, Mode),
		% For whatever reason some of the trace counts for a single
		% procedure or function can be split over multiple spans.
		% We collate them as if they appeared in a single span.
		(if svmap__remove(ProcLabel, Probe, !TraceCounts) then
			ProcData = Probe
		else
			ProcData = map__init
		),
		read_proc_trace_counts_2(ProcLabel, ProcData, !TraceCounts,
			!IO)
	else
		string__format("parse error on line %d of execution trace",
			[i(HeaderLineNum)], Message),
		throw(Message)
	).

:- pred read_proc_trace_counts_2(proc_label::in, proc_trace_counts::in,
	trace_counts::in, trace_counts::out, io::di, io::uo) is det.

read_proc_trace_counts_2(ProcLabel, ProcCounts0, !TraceCounts, !IO) :-
	io__get_line_number(LineNum, !IO),
	io__read_line_as_string(Result, !IO),
	(
		Result = ok(Line),
		(if parse_path_port_line(Line, PathPort, Count) then
			map__det_insert(ProcCounts0, PathPort, Count,
				ProcCounts),
			read_proc_trace_counts_2(ProcLabel, ProcCounts,
				!TraceCounts, !IO)
		else
			svmap__det_insert(ProcLabel, ProcCounts0,
				!TraceCounts),
			read_proc_trace_counts(LineNum, Line,
				!TraceCounts, !IO)
		)
	;
		Result = eof,
		svmap__det_insert(ProcLabel, ProcCounts0, !TraceCounts)
	;
		Result = error(Error),
		throw(Error)
	).

:- pred parse_path_port_line(string::in, path_port::out, int::out) is semidet.

parse_path_port_line(Line, PathPort, Count) :-
	Words = string__words(Line),
	(
		Words = [Word1, CountStr],
		( Port = string_to_trace_port(Word1) ->
			PathPort = port_only(Port)
		; Path = string_to_goal_path(Word1) ->
			PathPort = path_only(Path)
		;
			fail
		),
		string__to_int(CountStr, Count)
	;
		Words = [PortStr, PathStr, CountStr],
		Port = string_to_trace_port(PortStr),
		Path = string_to_goal_path(PathStr),
		PathPort = port_and_path(Port, Path),
		string__to_int(CountStr, Count)
	).

:- pred string_to_pred_or_func(string::in, pred_or_func::out) is semidet.

string_to_pred_or_func("p", predicate).
string_to_pred_or_func("f", function).

:- func string_to_trace_port(string) = trace_port is semidet.

string_to_trace_port("CALL") = call.
string_to_trace_port("EXIT") = exit.
string_to_trace_port("REDO") = redo.
string_to_trace_port("FAIL") = fail.
string_to_trace_port("EXCP") = exception.
string_to_trace_port("COND") = ite_cond.
string_to_trace_port("THEN") = ite_then.
string_to_trace_port("ELSE") = ite_else.
string_to_trace_port("NEGE") = neg_enter.
string_to_trace_port("NEGS") = neg_success.
string_to_trace_port("NEGF") = neg_failure.
string_to_trace_port("DISJ") = disj.
string_to_trace_port("SWTC") = switch.
string_to_trace_port("FRST") = nondet_pragma_first.
string_to_trace_port("LATR") = nondet_pragma_later.

:- func string_to_goal_path(string) = goal_path is semidet.

string_to_goal_path(String) = Path :-
	string__prefix(String, "<"),
	string__suffix(String, ">"),
	string__length(String, Length),
	string__substring(String, 1, Length-2, SubString),
	path_from_string(SubString, Path).
