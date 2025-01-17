%-----------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et
%-----------------------------------------------------------------------------%
%
% Another calculator - parses and evaluates integer expression terms.
% This module demonstrates the use of user-defined operator precedence
% tables with mercury_term_parser.read_term.
%
% Note that unlike calculator.m, the expressions must be terminated with a `.'.
% This version also allows variable assignments of the form `X = Exp.'.
%
% Author: stayl.
%
% This source file is hereby placed in the public domain.  -stayl.
%
%-----------------------------------------------------------------------------%

:- module calculator2.
:- interface.

:- import_module io.

:- pred main(io::di, io::uo) is cc_multi.

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- implementation.

:- import_module exception.
:- import_module int.
:- import_module list.
:- import_module map.
:- import_module maybe.
:- import_module mercury_term_parser.
:- import_module ops.
:- import_module pair.
:- import_module require.
:- import_module string.
:- import_module term.
:- import_module term_io.
:- import_module univ.
:- import_module varset.

%-----------------------------------------------------------------------------%

:- type calc_info == map(string, int).

main(!IO) :-
    main_2(map.init, !IO).

:- pred main_2(calc_info::in, io::di, io::uo) is cc_multi.

main_2(CalcInfo0, !IO) :-
    io.write_string("calculator> ", !IO),
    io.flush_output(!IO),
    mercury_term_parser.read_term_with_op_table(calculator_op_table, Res, !IO),
    (
        Res = error(Msg, _Line),
        io.write_string(Msg, !IO),
        io.nl(!IO),
        main(!IO)
    ;
        Res = eof,
        io.write_string("EOF\n", !IO)
    ;
        Res = term(VarSet, Term),
        ( if
            Term = term.functor(term.atom("="),
                [term.variable(Var, _Context), ExprTerm0], _)
        then
            ExprTerm = ExprTerm0,
            varset.lookup_name(VarSet, Var, VarName),
            SetVar = yes(VarName)
        else
            ExprTerm = Term,
            SetVar = no
        ),

        try(
            ( pred(Num0::out) is det :-
                Num0 = eval_expr(CalcInfo0, VarSet, ExprTerm)
            ), EvalResult),
        (
            EvalResult = succeeded(Num),
            io.write_int(Num, !IO),
            io.nl(!IO),
            ( if SetVar = yes(VarToSet) then
                map.set(VarToSet, Num, CalcInfo0, CalcInfo)
            else
                CalcInfo = CalcInfo0
            )
        ;
            EvalResult = exception(Exception),
            CalcInfo = CalcInfo0,
            ( if univ_to_type(Exception, EvalError) then
                report_eval_error(EvalError, !IO)
            else
                rethrow(EvalResult)
            )
        ),

        % Recursively call ourself for the next term(s).
        main_2(CalcInfo, !IO)
    ).

:- pred report_eval_error(eval_error::in, io::di, io::uo) is det.

report_eval_error(unknown_operator(Name, Arity), !IO) :-
    io.format("unknown operator `%s/%d'.\n", [s(Name), i(Arity)], !IO).
report_eval_error(unknown_variable(Name), !IO) :-
    io.format("unknown variable `%s'.\n", [s(Name)], !IO).
report_eval_error(unexpected_const(Const), !IO) :-
    io.write_string("unexpected ", !IO),
    (
        Const = term.float(Float),
        io.format("unexpected float `%f'\n", [f(Float)], !IO)
    ;
        Const = term.string(String),
        io.format("unexpected string ""%s""\n", [s(String)], !IO)
    ;
        ( Const = term.integer(_, _, _, _)
        ; Const = term.atom(_)
        ; Const = term.implementation_defined(_)
        ),
        error("report_eval_error")
    ).

:- func eval_expr(calc_info, varset, term) = int.

eval_expr(CalcInfo, VarSet, Term) = Res :-
    (
        Term = term.variable(Var, _Context),
        varset.lookup_name(VarSet, Var, VarName),
        ( if map.search(CalcInfo, VarName, Res0) then
            Res = Res0
        else
            throw(unknown_variable(VarName))
        )
    ;
        Term = term.functor(term.atom(Op), Args, _),
        ( if
            (
                Args = [Arg1],
                Res0 = eval_unop(Op, eval_expr(CalcInfo, VarSet, Arg1))
            ;
                Args = [Arg1, Arg2],
                Res0 = eval_binop(Op,
                    eval_expr(CalcInfo, VarSet, Arg1),
                    eval_expr(CalcInfo, VarSet, Arg2))
            )
        then
            Res = Res0
        else
            throw(unknown_operator(Op, list.length(Args)))
        )
    ;
        Term = term.functor(Const, _, Context),
        Const = term.integer(_, _, _, _),
        ( if term_to_int(Term, Int) then
            Res = Int
        else
            throw(unexpected_const(Const) - Context)
        )
    ;
        Term = term.functor(term.float(Float), _, Context),
        throw(unexpected_const(term.float(Float)) - Context)
    ;
        Term = term.functor(term.string(String), _, Context),
        throw(unexpected_const(term.string(String)) - Context)
    ;
        Term =  term.functor(ImplDefConst, _, Context),
        ImplDefConst = term.implementation_defined(_),
        throw(unexpected_const(ImplDefConst) - Context)
    ).

:- func eval_unop(string, int) = int is semidet.

eval_unop("-", Num) = -Num.
eval_unop("+", Num) = Num.

:- func eval_binop(string, int, int) = int is semidet.

eval_binop("-", Num1, Num2) = Num1 - Num2.
eval_binop("+", Num1, Num2) = Num1 + Num2.
eval_binop("*", Num1, Num2) = Num1 * Num2.
eval_binop("//", Num1, Num2) = Num1 // Num2.

:- type eval_error
    --->    unknown_operator(
                string,     % name
                int         % arity
            )
    ;       unknown_variable(string)
    ;       unexpected_const(term.const).

:- type calculator_op_table ---> calculator_op_table.

:- pred calculator2.ops_table(string::in, op_info::out, list(op_info)::out)
    is semidet.

calculator2.ops_table("//", op_info(infix(y, x), 400), []).
calculator2.ops_table("*",  op_info(infix(y, x), 400), []).
calculator2.ops_table("+",  op_info(infix(y, x), 500),
    [op_info(prefix(x), 500)]).
calculator2.ops_table("-",  op_info(infix(y, x), 500),
    [op_info(prefix(x), 200)]).
calculator2.ops_table("=", op_info(infix(x, x), 700), []).

:- instance ops.op_table(calculator_op_table) where [

    ( ops.lookup_infix_op(_, Op, Priority, LeftAssoc, RightAssoc) :-
        calculator2.ops_table(Op, Info, _),
        Info = op_info(infix(LeftAssoc, RightAssoc), Priority)
    ),

    ops.lookup_operator_term(_, _, _, _) :- fail,

    ( ops.lookup_prefix_op(_, Op, Priority, LeftAssoc) :-
        calculator2.ops_table(Op, _, OtherInfo),
        OtherInfo = [op_info(prefix(LeftAssoc), Priority)]
    ),

    ops.lookup_postfix_op(_, _, _, _) :- fail,
    ops.lookup_binary_prefix_op(_, _, _, _, _) :- fail,

    ops.lookup_op(Table, Op) :- ops.lookup_infix_op(Table, Op, _, _, _),
    ops.lookup_op(Table, Op) :- ops.lookup_prefix_op(Table, Op, _, _),
    ops.lookup_op(Table, Op) :-
        ops.lookup_binary_prefix_op(Table, Op, _, _, _),
    ops.lookup_op(Table, Op) :- ops.lookup_postfix_op(Table, Op, _, _),

    ops.lookup_op_infos(_, Op, OpInfo, OtherInfos) :-
        calculator2.ops_table(Op, OpInfo, OtherInfos),

    ops.max_priority(_) = 700,
    ops.arg_priority(Table) = ops.max_priority(Table) + 1
].

%-----------------------------------------------------------------------------%
:- end_module calculator2.
%-----------------------------------------------------------------------------%
