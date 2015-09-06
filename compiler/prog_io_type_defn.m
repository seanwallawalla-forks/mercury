%-----------------------------------------------------------------------------e
% vim: ft=mercury ts=4 sw=4 et
%-----------------------------------------------------------------------------e
% Copyright (C) 2008-2011 The University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%-----------------------------------------------------------------------------%
%
% File: prog_io_type_defn.m.
%
% This module parses type definitions.
%
%-----------------------------------------------------------------------------%

:- module parse_tree.prog_io_type_defn.

:- interface.

:- import_module mdbcomp.sym_name.
:- import_module parse_tree.prog_data.
:- import_module parse_tree.prog_item.
:- import_module parse_tree.prog_io_util.

:- import_module list.
:- import_module maybe.
:- import_module term.
:- import_module varset.

    % Parse the definition of a type.
    %
:- pred parse_type_defn(module_name::in, varset::in, term::in, decl_attrs::in,
    prog_context::in, int::in, maybe1(item)::out) is det.

    % parse_type_defn_head(ModuleName, VarSet, Head, HeadResult):
    %
    % Check the head of a type definition for errors.
    %
:- pred parse_type_defn_head(module_name::in, varset::in, term::in,
    maybe2(sym_name, list(type_param))::out) is det.

    % parse_type_decl_where_part_if_present(TypeSymName, Arity,
    %   IsSolverType, Inst, ModuleName, Term0, Term, Result):
    %
    % Checks if Term0 is a term of the form `<body> where <attributes>'.
    % If so, returns the `<body>' in Term and the parsed `<attributes>'
    % in Result. If not, returns Term = Term0 and Result = no.
    %
:- pred parse_type_decl_where_part_if_present(is_solver_type::in,
    module_name::in, varset::in, term::in, term::out,
    maybe3(maybe(solver_type_details), maybe(unify_compare),
        maybe(list(sym_name_and_arity)))::out) is det.

%-----------------------------------------------------------------------------%

:- implementation.

:- import_module libs.globals.
:- import_module parse_tree.error_util.
:- import_module parse_tree.parse_tree_out_term.
:- import_module parse_tree.prog_io_mutable.
:- import_module parse_tree.prog_io_sym_name.
:- import_module parse_tree.prog_io_typeclass.
:- import_module parse_tree.prog_mode.
:- import_module parse_tree.prog_type.

:- import_module bag.
:- import_module bool.
:- import_module pair.
:- import_module require.
:- import_module set.
:- import_module string.
:- import_module unit.

parse_type_defn(ModuleName, VarSet, TypeDefnTerm, Attributes, Context,
        SeqNum, MaybeItem) :-
    ( if
        TypeDefnTerm = term.functor(term.atom(Name), ArgTerms, _),
        ArgTerms = [HeadTerm, BodyTerm],
        ( Name = "--->"
        ; Name = "=="
        ; Name = "where"
        )
    then
        (
            Name = "--->",
            parse_du_type_defn(ModuleName, VarSet, HeadTerm, BodyTerm,
                Attributes, Context, SeqNum, MaybeItem)
        ;
            Name = "==",
            parse_eqv_type_defn(ModuleName, VarSet, HeadTerm, BodyTerm,
                Attributes, Context, SeqNum, MaybeItem)
        ;
            Name = "where",
            parse_where_block_type_defn(ModuleName, VarSet, HeadTerm, BodyTerm,
                Attributes, Context, SeqNum, MaybeItem)
        )
    else
        parse_abstract_type_defn(ModuleName, VarSet, TypeDefnTerm, Attributes,
            Context, SeqNum, MaybeItem)
    ).

%-----------------------------------------------------------------------------%
%
% Code dealing with definitions of discriminated union types.
%

    % parse_du_type_defn parses the definition of a discriminated union type.
    %
:- pred parse_du_type_defn(module_name::in, varset::in, term::in, term::in,
    decl_attrs::in, prog_context::in, int::in, maybe1(item)::out) is det.

parse_du_type_defn(ModuleName, VarSet, HeadTerm, BodyTerm, Attributes0,
        Context, SeqNum, MaybeItem) :-
    get_is_solver_type(IsSolverType, Attributes0, Attributes),
    (
        IsSolverType = solver_type,
        SolverPieces = [words("Error: a solver type"),
            words("cannot have data constructors."), nl],
        SolverSpec = error_spec(severity_error, phase_term_to_parse_tree,
            [simple_msg(get_term_context(HeadTerm), [always(SolverPieces)])]),
        SolverSpecs = [SolverSpec]
    ;
        IsSolverType = non_solver_type,
        SolverSpecs = []
    ),

    parse_type_defn_head(ModuleName, VarSet, HeadTerm, MaybeTypeCtorAndArgs),
    du_type_rhs_ctors_and_where_terms(BodyTerm, CtorsTerm, MaybeWhereTerm),
    MaybeOneOrMoreCtors = parse_constructors(ModuleName, VarSet, CtorsTerm),
    (
        MaybeWhereTerm = no,
        MaybeWhere = ok3(no, no, no)
    ;
        MaybeWhereTerm = yes(WhereTerm),
        parse_type_decl_where_term(non_solver_type, ModuleName, VarSet,
            WhereTerm, MaybeWhere)
    ),
    ( if
        SolverSpecs = [],
        MaybeTypeCtorAndArgs = ok2(Name, Params),
        MaybeOneOrMoreCtors = ok1(OneOrMoreCtors),
        MaybeWhere = ok3(SolverTypeDetails, MaybeUserEqComp,
            MaybeDirectArgIs)
    then
        % We asked parse_type_decl_where_term to return an error if
        % WhereTerm contains solver attributes, so we shouldn't get here
        % if SolverTypeDetails is yes(...).
        expect(unify(SolverTypeDetails, no), $module, $pred,
            "discriminated union type has solver type details"),
        OneOrMoreCtors = one_or_more(HeadCtor, TailCtors),
        Ctors = [HeadCtor | TailCtors],
        process_du_ctors(Params, VarSet, BodyTerm, Ctors, [], CtorsSpecs),
        (
            MaybeDirectArgIs = yes(DirectArgCtors),
            check_direct_arg_ctors(Ctors, DirectArgCtors, BodyTerm,
                CtorsSpecs, ErrorSpecs)
        ;
            MaybeDirectArgIs = no,
            ErrorSpecs = CtorsSpecs
        ),
        (
            ErrorSpecs = [],
            varset.coerce(VarSet, TypeVarSet),
            TypeDefn = parse_tree_du_type(Ctors, MaybeUserEqComp,
                MaybeDirectArgIs),
            ItemTypeDefn = item_type_defn_info(Name, Params, TypeDefn,
                TypeVarSet, Context, SeqNum),
            Item = item_type_defn(ItemTypeDefn),
            MaybeItem0 = ok1(Item),
            check_no_attributes(MaybeItem0, Attributes, MaybeItem)
        ;
            ErrorSpecs = [_ | _],
            MaybeItem = error1(ErrorSpecs)
        )
    else
        Specs = SolverSpecs ++
            get_any_errors2(MaybeTypeCtorAndArgs) ++
            get_any_errors1(MaybeOneOrMoreCtors) ++
            get_any_errors3(MaybeWhere),
        MaybeItem = error1(Specs)
    ).

:- pred du_type_rhs_ctors_and_where_terms(term::in,
    term::out, maybe(term)::out) is det.

du_type_rhs_ctors_and_where_terms(Term, CtorsTerm, MaybeWhereTerm) :-
    ( if
        Term = term.functor(term.atom("where"), Args, _Context),
        Args = [CtorsTermPrime, WhereTerm]
    then
        CtorsTerm = CtorsTermPrime,
        MaybeWhereTerm = yes(WhereTerm)
    else
        CtorsTerm = Term,
        MaybeWhereTerm = no
    ).

    % Convert a list of terms separated by semi-colons (known as a
    % "disjunction", even thought the terms aren't goals in this case)
    % into a list of constructors.
    %
:- func parse_constructors(module_name, varset, term) =
    maybe1(one_or_more(constructor)).

parse_constructors(ModuleName, VarSet, Term) = MaybeConstructors :-
    disjunction_to_one_or_more(Term, one_or_more(HeadBodyTerm, TailBodyTerms)),
    parse_constructors_loop(ModuleName, VarSet, HeadBodyTerm, TailBodyTerms,
        MaybeConstructors).

    % Try to parse the term as a list of constructors.
    %
:- pred parse_constructors_loop(module_name::in, varset::in,
    term::in, list(term)::in, maybe1(one_or_more(constructor))::out) is det.

parse_constructors_loop(ModuleName, VarSet, Head, Tail, MaybeConstructors) :-
    MaybeHeadConstructor = parse_constructor(ModuleName, VarSet, Head),
    (
        Tail = [],
        (
            MaybeHeadConstructor = ok1(HeadConstructor),
            MaybeConstructors = ok1(one_or_more(HeadConstructor, []))
        ;
            MaybeHeadConstructor = error1(Specs),
            MaybeConstructors = error1(Specs)
        )
    ;
        Tail = [HeadTail | TailTail],
        parse_constructors_loop(ModuleName, VarSet, HeadTail, TailTail,
            MaybeTailConstructors),
        ( if
            MaybeHeadConstructor = ok1(HeadConstructor),
            MaybeTailConstructors = ok1(TailConstructors)
        then
            MaybeConstructors =
                ok1(one_or_more_cons(HeadConstructor, TailConstructors))
        else
            Specs = get_any_errors1(MaybeHeadConstructor) ++
                get_any_errors1(MaybeTailConstructors),
            MaybeConstructors = error1(Specs)
        )
    ).

:- func parse_constructor(module_name, varset, term) = maybe1(constructor).

parse_constructor(ModuleName, VarSet, Term) = MaybeConstructor :-
    ( if Term = term.functor(term.atom("some"), [VarsTerm, SubTerm], _) then
        ( if parse_list_of_vars(VarsTerm, ExistQVars) then
            list.map(term.coerce_var, ExistQVars, ExistQTVars),
            MaybeConstructor = parse_constructor_2(ModuleName, VarSet,
                ExistQTVars, SubTerm)
        else
            TermStr = describe_error_term(VarSet, Term),
            Pieces = [words("Error: syntax error in variable list at"),
                words(TermStr), suffix("."), nl],
            Spec = error_spec(severity_error, phase_term_to_parse_tree,
                [simple_msg(get_term_context(VarsTerm), [always(Pieces)])]),
            MaybeConstructor = error1([Spec])
        )
    else
        ExistQVars = [],
        MaybeConstructor = parse_constructor_2(ModuleName, VarSet, ExistQVars,
            Term)
    ).

:- func parse_constructor_2(module_name, varset, list(tvar), term) =
    maybe1(constructor).

parse_constructor_2(ModuleName, VarSet, ExistQVars, Term) = MaybeConstructor :-
    get_existential_constraints_from_term(ModuleName, VarSet, Term,
        BeforeConstraintsTerm, MaybeConstraints),
    (
        MaybeConstraints = error1(Specs),
        MaybeConstructor = error1(Specs)
    ;
        MaybeConstraints = ok1(Constraints),
        ( if
            % Note that as a special case, one level of curly braces around
            % the constructor are ignored. This is to allow you to define
            % ';'/2 and 'some'/2 constructors.
            BeforeConstraintsTerm = term.functor(term.atom("{}"),
                [InsideBracesTerm], _Context)
        then
            MainTerm = InsideBracesTerm
        else
            MainTerm = BeforeConstraintsTerm
        ),
        ContextPieces = [words("In constructor definition:")],
        parse_implicitly_qualified_sym_name_and_args(ModuleName, MainTerm,
            VarSet, ContextPieces, MaybeFunctorAndArgTerms),
        (
            MaybeFunctorAndArgTerms = error2(Specs),
            MaybeConstructor  = error1(Specs)
        ;
            MaybeFunctorAndArgTerms = ok2(Functor, ArgTerms),
            MaybeConstructorArgs = convert_constructor_arg_list(ModuleName,
                VarSet, ArgTerms),
            (
                MaybeConstructorArgs = error1(Specs),
                MaybeConstructor = error1(Specs)
            ;
                MaybeConstructorArgs = ok1(ConstructorArgs),
                Ctor = ctor(ExistQVars, Constraints, Functor, ConstructorArgs,
                    list.length(ConstructorArgs), get_term_context(MainTerm)),
                MaybeConstructor = ok1(Ctor)
            )
        )
    ).

:- pred get_existential_constraints_from_term(module_name::in, varset::in,
    term::in, term::out, maybe1(list(prog_constraint))::out) is det.

get_existential_constraints_from_term(ModuleName, VarSet, !PredTypeTerm,
        MaybeExistentialConstraints) :-
    ( if
        !.PredTypeTerm = term.functor(term.atom("=>"),
            [!:PredTypeTerm, ExistentialConstraints], _)
    then
        parse_class_constraints(ModuleName, VarSet, ExistentialConstraints,
            MaybeExistentialConstraints)
    else
        MaybeExistentialConstraints = ok1([])
    ).

:- func convert_constructor_arg_list(module_name, varset, list(term)) =
    maybe1(list(constructor_arg)).

convert_constructor_arg_list(_, _, []) = ok1([]).
convert_constructor_arg_list(ModuleName, VarSet, [Term | Terms])
        = MaybeConstructorArgs :-
    ( if Term = term.functor(term.atom("::"), [NameTerm, TypeTerm], _) then
        ContextPieces = [words("In field name:")],
        parse_implicitly_qualified_sym_name_and_args(ModuleName, NameTerm,
            VarSet, ContextPieces, MaybeSymNameAndArgs),
        (
            MaybeSymNameAndArgs = error2(Specs),
            MaybeConstructorArgs = error1(Specs)
        ;
            MaybeSymNameAndArgs = ok2(SymName, SymNameArgs),
            (
                SymNameArgs = [_ | _],
                % XXX Should we add "... at function symbol ..."?
                Pieces = [words("Error: syntax error in constructor name."),
                    nl],
                Spec = error_spec(severity_error, phase_term_to_parse_tree,
                    [simple_msg(get_term_context(Term), [always(Pieces)])]),
                MaybeConstructorArgs = error1([Spec])
            ;
                SymNameArgs = [],
                NameCtxt = get_term_context(NameTerm),
                MaybeCtorFieldName = yes(ctor_field_name(SymName, NameCtxt)),
                MaybeConstructorArgs =
                    convert_constructor_arg_list_2(ModuleName,
                        VarSet, MaybeCtorFieldName, TypeTerm, Terms)
            )
        )
    else
        MaybeCtorFieldName = no,
        TypeTerm = Term,
        MaybeConstructorArgs = convert_constructor_arg_list_2(ModuleName,
            VarSet, MaybeCtorFieldName, TypeTerm, Terms)
    ).

:- func convert_constructor_arg_list_2(module_name, varset,
    maybe(ctor_field_name), term, list(term)) = maybe1(list(constructor_arg)).

convert_constructor_arg_list_2(ModuleName, VarSet, MaybeCtorFieldName,
        TypeTerm, Terms) = MaybeArgs :-
    ContextPieces = [words("In type definition:")],
    parse_type(TypeTerm, VarSet, ContextPieces, MaybeType),
    (
        MaybeType = ok1(Type),
        Context = get_term_context(TypeTerm),
        % Initially every argument is assumed to occupy one word.
        Arg = ctor_arg(MaybeCtorFieldName, Type, full_word, Context),
        MaybeTailArgs =
            convert_constructor_arg_list(ModuleName, VarSet, Terms),
        (
            MaybeTailArgs = error1(Specs),
            MaybeArgs  = error1(Specs)
        ;
            MaybeTailArgs = ok1(Args),
            MaybeArgs  = ok1([Arg | Args])
        )
    ;
        MaybeType = error1(Specs),
        MaybeArgs = error1(Specs)
    ).

:- pred process_du_ctors(list(type_param)::in, varset::in, term::in,
    list(constructor)::in, list(error_spec)::in, list(error_spec)::out) is det.

process_du_ctors(_Params, _, _, [], !Specs).
process_du_ctors(Params, VarSet, BodyTerm, [Ctor | Ctors], !Specs) :-
    Ctor = ctor(ExistQVars, Constraints, _CtorName, CtorArgs, _Arity,
        _Context),
    ( if
        % Check that all type variables in the ctor are either explicitly
        % existentially quantified or occur in the head of the type.

        CtorArgTypes = list.map(func(C) = C ^ arg_type, CtorArgs),
        type_vars_list(CtorArgTypes, VarsInCtorArgTypes0),
        list.sort_and_remove_dups(VarsInCtorArgTypes0, VarsInCtorArgTypes),
        list.filter(list.contains(ExistQVars ++ Params), VarsInCtorArgTypes,
            _ExistQOrParamVars, NotExistQOrParamVars),
        NotExistQOrParamVars = [_ | _]
    then
        % There should be no duplicate names to remove.
        varset.coerce(VarSet, GenericVarSet),
        NotExistQOrParamVarsStr =
            mercury_vars_to_name_only(GenericVarSet, NotExistQOrParamVars),
        Pieces = [words("Error: free type"),
            words(choose_number(NotExistQOrParamVars,
                "parameter", "parameters")),
            words(NotExistQOrParamVarsStr),
            words("in RHS of type definition."), nl],
        Spec = error_spec(severity_error, phase_term_to_parse_tree,
            [simple_msg(get_term_context(BodyTerm), [always(Pieces)])]),
        !:Specs = [Spec | !.Specs]
    else if
        % Check that all type variables in existential quantifiers do not
        % occur in the head (maybe this should just be a warning, not an error?
        % If we were to allow it, we would need to rename them apart.)

        set.list_to_set(ExistQVars, ExistQVarsSet),
        set.list_to_set(Params, ParamsSet),
        set.intersect(ExistQVarsSet, ParamsSet, ExistQParamsSet),
        set.is_non_empty(ExistQParamsSet)
    then
        % There should be no duplicate names to remove.
        set.to_sorted_list(ExistQParamsSet, ExistQParams),
        varset.coerce(VarSet, GenericVarSet),
        ExistQParamVarsStrs =
            list.map(mercury_var_to_name_only(GenericVarSet), ExistQParams),
        Pieces = [words("Error:"),
            words(choose_number(ExistQParams,
                "type variable", "type variables"))] ++
            list_to_quoted_pieces(ExistQParamVarsStrs) ++
            [words(choose_number(ExistQParams, "has", "have")),
            words("overlapping scopes"),
            words("(explicit type quantifier shadows argument type)."), nl],
        Spec = error_spec(severity_error, phase_term_to_parse_tree,
            [simple_msg(get_term_context(BodyTerm), [always(Pieces)])]),
        !:Specs = [Spec | !.Specs]
    else if
        % Check that all type variables in existential quantifiers occur
        % somewhere in the constructor argument types or constraints.

        CtorArgTypes = list.map(func(C) = C ^ arg_type, CtorArgs),
        type_vars_list(CtorArgTypes, VarsInCtorArgTypes0),
        list.sort_and_remove_dups(VarsInCtorArgTypes0, VarsInCtorArgTypes),
        constraint_list_get_tvars(Constraints, ConstraintTVars),
        list.filter(list.contains(VarsInCtorArgTypes ++ ConstraintTVars),
            ExistQVars, _OccursExistQVars, NotOccursExistQVars),
        NotOccursExistQVars = [_ | _]
    then
        % There should be no duplicate names to remove.
        varset.coerce(VarSet, GenericVarSet),
        NotOccursExistQVarsStr =
            mercury_vars_to_name_only(GenericVarSet, NotOccursExistQVars),
        Pieces = [words("Error:"),
            words(choose_number(NotOccursExistQVars,
                "type variable", "type variables")),
            words(NotOccursExistQVarsStr),
            words("in existential quantifier"),
            words(choose_number(NotOccursExistQVars,
                "does not occur", "do not occur")),
            words("in arguments or constraints of constructor."), nl],
        Spec = error_spec(severity_error, phase_term_to_parse_tree,
            [simple_msg(get_term_context(BodyTerm), [always(Pieces)])]),
        !:Specs = [Spec | !.Specs]
    else if
        % Check that all type variables in existential constraints occur in
        % the existential quantifiers.

        ConstraintArgTypeLists =
            list.map(prog_constraint_get_arg_types, Constraints),
        list.condense(ConstraintArgTypeLists, ConstraintArgTypes),
        type_vars_list(ConstraintArgTypes, VarsInCtorArgTypes0),
        list.sort_and_remove_dups(VarsInCtorArgTypes0, VarsInCtorArgTypes),
        list.filter(list.contains(ExistQVars), VarsInCtorArgTypes,
            _ExistQArgTypes, NotExistQArgTypes),
        NotExistQArgTypes = [_ | _]
    then
        varset.coerce(VarSet, GenericVarSet),
        NotExistQArgTypesStr =
            mercury_vars_to_name_only(GenericVarSet, NotExistQArgTypes),
        Pieces = [words("Error:"),
            words(choose_number(NotExistQArgTypes,
                "type variable", "type variables")),
            words(NotExistQArgTypesStr),
            words("in class constraints,"),
            words(choose_number(NotExistQArgTypes,
                "which was", "which were")),
            words("introduced with"), quote("=>"),
            words("must be explicitly existentially quantified"),
            words("using"), quote("some"), suffix("."), nl],
        Spec = error_spec(severity_error, phase_term_to_parse_tree,
            [simple_msg(get_term_context(BodyTerm), [always(Pieces)])]),
        !:Specs = [Spec | !.Specs]
    else
        true
    ),
    process_du_ctors(Params, VarSet, BodyTerm, Ctors, !Specs).

:- pred check_direct_arg_ctors(list(constructor)::in,
    list(sym_name_and_arity)::in, term::in,
    list(error_spec)::in, list(error_spec)::out) is det.

check_direct_arg_ctors(_Ctors, [], _ErrorTerm, !Specs).
check_direct_arg_ctors(Ctors, [DirectArgCtor | DirectArgCtors], ErrorTerm,
        !Specs) :-
    DirectArgCtor = SymName / Arity,
    ( if find_constructor(Ctors, SymName, Arity, Ctor) then
        Ctor = ctor(ExistQVars, _Constraints, _SymName, _Args, _Arity,
            _Context),
        ( if Arity \= 1 then
            Pieces = [words("Error: the"), quote("direct_arg"),
                words("attribute contains a function symbol whose arity"),
                words("is not 1."), nl],
            Spec = error_spec(severity_error, phase_term_to_parse_tree,
                [simple_msg(get_term_context(ErrorTerm), [always(Pieces)])]),
            !:Specs = [Spec | !.Specs]
        else
            (
                ExistQVars = []
            ;
                ExistQVars = [_ | _],
                Pieces = [words("Error: the"), quote("direct_arg"),
                    words("attribute contains a function symbol"),
                    sym_name_and_arity(DirectArgCtor),
                    words("with existentially quantified type variables."),
                    nl],
                Spec = error_spec(severity_error, phase_term_to_parse_tree,
                    [simple_msg(get_term_context(ErrorTerm),
                        [always(Pieces)])]),
                !:Specs = [Spec | !.Specs]
            )
        )
    else
        Pieces = [words("Error: the"), quote("direct_arg"),
            words("attribute lists the function symbol"),
            sym_name_and_arity(DirectArgCtor),
            words("which is not in the type definition."), nl],
        Spec = error_spec(severity_error, phase_term_to_parse_tree,
            [simple_msg(get_term_context(ErrorTerm), [always(Pieces)])]),
        !:Specs = [Spec | !.Specs]
    ),
    check_direct_arg_ctors(Ctors, DirectArgCtors, ErrorTerm, !Specs).

:- pred find_constructor(list(constructor)::in, sym_name::in, arity::in,
    constructor::out) is semidet.

find_constructor([Ctor | Ctors], SymName, Arity, NamedCtor) :-
    ( if Ctor = ctor(_, _, SymName, _Args, Arity, _) then
        NamedCtor = Ctor
    else
        find_constructor(Ctors, SymName, Arity, NamedCtor)
    ).

%-----------------------------------------------------------------------------%

    % parse_eqv_type_defn parses the definition of an equivalence type.
    %
:- pred parse_eqv_type_defn(module_name::in, varset::in, term::in, term::in,
    decl_attrs::in, prog_context::in, int::in, maybe1(item)::out) is det.

parse_eqv_type_defn(ModuleName, VarSet, HeadTerm, BodyTerm, Attributes,
        Context, SeqNum, MaybeItem) :-
    parse_type_defn_head(ModuleName, VarSet, HeadTerm, MaybeNameAndParams),
    % XXX Should pass more correct ContextPieces.
    ContextPieces = [],
    parse_type(BodyTerm, VarSet, ContextPieces, MaybeType),
    ( if
        MaybeNameAndParams = ok2(Name, ParamTVars),
        MaybeType = ok1(Type)
    then
        varset.coerce(VarSet, TVarSet),
        check_no_free_body_vars(TVarSet, ParamTVars, Type,
            get_term_context(BodyTerm), FreeSpecs),
        (
            FreeSpecs = [],
            TypeDefn = parse_tree_eqv_type(Type),
            ItemTypeDefn = item_type_defn_info(Name, ParamTVars, TypeDefn,
                TVarSet, Context, SeqNum),
            Item = item_type_defn(ItemTypeDefn),
            MaybeItem0 = ok1(Item),
            check_no_attributes(MaybeItem0, Attributes, MaybeItem)
        ;
            FreeSpecs = [_ | _],
            MaybeItem = error1(FreeSpecs)
        )
    else
        Specs = get_any_errors2(MaybeNameAndParams) ++
            get_any_errors1(MaybeType),
        MaybeItem = error1(Specs)
    ).

%-----------------------------------------------------------------------------%

    % Parse a type definition which consists only of a `where' block.
    % This is either an abstract enumeration type, or a solver type.
    %
:- pred parse_where_block_type_defn(module_name::in, varset::in, term::in,
    term::in, decl_attrs::in, prog_context::in, int::in,
    maybe1(item)::out) is det.

parse_where_block_type_defn(ModuleName, VarSet, HeadTerm, BodyTerm,
        Attributes0, Context, SeqNum, MaybeItem) :-
    get_is_solver_type(IsSolverType, Attributes0, Attributes),
    (
        IsSolverType = non_solver_type,
        parse_where_type_is_abstract_enum(ModuleName, VarSet, HeadTerm,
            BodyTerm, Context, SeqNum, MaybeItem)
    ;
        IsSolverType = solver_type,
        parse_type_decl_where_term(solver_type, ModuleName, VarSet, BodyTerm,
            MaybeWhere),
        (
            MaybeWhere = error3(Specs),
            MaybeItem = error1(Specs)
        ;
            MaybeWhere = ok3(MaybeSolverTypeDetails, MaybeUserEqComp,
                MaybeDirectArgCtors),
            (
                MaybeDirectArgCtors = yes(_),
                Pieces = [words("Error: solver type definitions"),
                    words("cannot have a"), quote("direct_arg"),
                    words("attribute."), nl],
                Spec = error_spec(severity_error, phase_term_to_parse_tree,
                    [simple_msg(get_term_context(HeadTerm),
                        [always(Pieces)])]),
                MaybeItem = error1([Spec])
            ;
                MaybeDirectArgCtors = no,
                parse_solver_type_base(ModuleName, VarSet, HeadTerm,
                    MaybeSolverTypeDetails, MaybeUserEqComp, Attributes,
                    Context, SeqNum, MaybeItem)
            )
        )
    ).

:- pred parse_where_type_is_abstract_enum(module_name::in, varset::in,
    term::in, term::in, prog_context::in, int::in, maybe1(item)::out) is det.

parse_where_type_is_abstract_enum(ModuleName, VarSet, HeadTerm, BodyTerm,
        Context, SeqNum, MaybeItem) :-
    varset.coerce(VarSet, TypeVarSet),
    parse_type_defn_head(ModuleName, VarSet, HeadTerm, MaybeNameParams),
    ( if
        BodyTerm = term.functor(term.atom("type_is_abstract_enum"), Args, _)
    then
        ( if
            Args = [Arg],
            Arg = term.functor(integer(NumBits), [], _)
        then
            TypeDefn0 = parse_tree_abstract_type(abstract_enum_type(NumBits)),
            MaybeTypeDefn = ok1(TypeDefn0)
        else
            Pieces = [words("Error: invalid argument for"),
                words("type_is_abstract_enum."), nl],
            Spec = error_spec(severity_error, phase_term_to_parse_tree,
                [simple_msg(Context, [always(Pieces)])]),
            MaybeTypeDefn = error1([Spec])
        )
    else
        Pieces = [words("Error: invalid"), quote("where ..."),
            words("attributes for abstract non-solver type."), nl],
        Spec = error_spec(severity_error, phase_term_to_parse_tree,
            [simple_msg(Context, [always(Pieces)])]),
        MaybeTypeDefn = error1([Spec])
    ),
    ( if
        MaybeNameParams = ok2(Name, Params),
        MaybeTypeDefn = ok1(TypeDefn)
    then
        ItemTypeDefn = item_type_defn_info(Name, Params, TypeDefn,
            TypeVarSet, Context, SeqNum),
        Item = item_type_defn(ItemTypeDefn),
        MaybeItem = ok1(Item)
    else
        Specs = get_any_errors2(MaybeNameParams) ++
            get_any_errors1(MaybeTypeDefn),
        MaybeItem = error1(Specs)
    ).

:- pred parse_solver_type_base(module_name::in, varset::in, term::in,
    maybe(solver_type_details)::in, maybe(unify_compare)::in,
    decl_attrs::in, prog_context::in, int::in, maybe1(item)::out) is det.

parse_solver_type_base(ModuleName, VarSet, HeadTerm,
        MaybeSolverTypeDetails, MaybeUserEqComp, Attributes,
        Context, SeqNum, MaybeItem) :-
    varset.coerce(VarSet, TVarSet),
    parse_type_defn_head(ModuleName, VarSet, HeadTerm, MaybeNameParams),
    (
        MaybeSolverTypeDetails = yes(_),
        SolverSpecs = []
    ;
        MaybeSolverTypeDetails = no,
        Pieces = [words("Solver type with no solver_type_details."), nl],
        SolverSpec = error_spec(severity_error, phase_term_to_parse_tree,
            [simple_msg(get_term_context(HeadTerm), [always(Pieces)])]),
        SolverSpecs = [SolverSpec]
    ),
    ( if
        MaybeNameParams = ok2(_SymName, ParamTVars0),
        MaybeSolverTypeDetails = yes(SolverTypeDetails0)
    then
        RepType = SolverTypeDetails0 ^ std_representation_type,
        check_no_free_body_vars(TVarSet, ParamTVars0, RepType, Context,
            FreeSpecs)
    else
        FreeSpecs = []
    ),
    ( if
        MaybeNameParams = ok2(SymName, ParamTVars),
        MaybeSolverTypeDetails = yes(SolverTypeDetails),
        FreeSpecs = []
    then
        TypeDefn = parse_tree_solver_type(SolverTypeDetails, MaybeUserEqComp),
        ItemTypeDefn = item_type_defn_info(SymName, ParamTVars, TypeDefn,
            TVarSet, Context, SeqNum),
        Item = item_type_defn(ItemTypeDefn),
        MaybeItem0 = ok1(Item),
        check_no_attributes(MaybeItem0, Attributes, MaybeItem)
    else
        Specs = SolverSpecs ++ get_any_errors2(MaybeNameParams) ++ FreeSpecs,
        MaybeItem = error1(Specs)
    ).

%-----------------------------------------------------------------------------%
%
% Parse an abstract type definition.
%

:- pred parse_abstract_type_defn(module_name::in, varset::in, term::in,
    decl_attrs::in, prog_context::in, int::in, maybe1(item)::out) is det.

parse_abstract_type_defn(ModuleName, VarSet, HeadTerm, Attributes0,
        Context, SeqNum, MaybeItem) :-
    parse_type_defn_head(ModuleName, VarSet, HeadTerm, MaybeTypeCtorAndArgs),
    get_is_solver_type(IsSolverType, Attributes0, Attributes),
    (
        MaybeTypeCtorAndArgs = error2(Specs),
        MaybeItem = error1(Specs)
    ;
        MaybeTypeCtorAndArgs = ok2(Name, Params),
        varset.coerce(VarSet, TypeVarSet),
        (
            IsSolverType = non_solver_type,
            AbstractTypeDetails = abstract_type_general
        ;
            IsSolverType = solver_type,
            AbstractTypeDetails = abstract_solver_type
        ),
        TypeDefn = parse_tree_abstract_type(AbstractTypeDetails),
        ItemTypeDefn = item_type_defn_info(Name, Params, TypeDefn,
            TypeVarSet, Context, SeqNum),
        Item = item_type_defn(ItemTypeDefn),
        MaybeItem0 = ok1(Item),
        check_no_attributes(MaybeItem0, Attributes, MaybeItem)
    ).

%-----------------------------------------------------------------------------%
%
% Parse ... where ... clauses in type definitions. These clauses can specify
% type-specific unify and/or compare predicates for discriminated union types
% and solver type details for solver types.
%

parse_type_decl_where_part_if_present(IsSolverType, ModuleName, VarSet,
        Term, BeforeWhereTerm, MaybeWhereDetails) :-
    % The optional `where ...' part of the type definition syntax
    % is a comma separated list of special type `attributes'.
    %
    % The possible attributes (in this order) are either
    % - `type_is_abstract_noncanonical' on its own appears only in .int2
    %   files and indicates that the type has user-defined equality and/or
    %   comparison, but that what these predicates are is not known at
    %   this point
    % or
    % - `representation is <<type name>>' (required for solver types)
    % - `initialisation is <<pred name>>' (required for solver types)
    % - `ground is <<inst>>' (required for solver types)
    % - `any is <<inst>>' (required for solver types)
    % - `equality is <<pred name>>' (optional)
    % - `comparison is <<pred name>>' (optional).
    %
    ( if
        Term = term.functor(term.atom("where"),
            [BeforeWhereTermPrime, WhereTerm], _)
    then
        BeforeWhereTerm = BeforeWhereTermPrime,
        parse_type_decl_where_term(IsSolverType, ModuleName, VarSet, WhereTerm,
            MaybeWhereDetails)
    else
        BeforeWhereTerm = Term,
        MaybeWhereDetails = ok3(no, no, no)
    ).

:- pred parse_type_decl_where_term(is_solver_type::in, module_name::in,
    varset::in, term::in,
    maybe3(maybe(solver_type_details), maybe(unify_compare),
        maybe(list(sym_name_and_arity)))::out) is det.

parse_type_decl_where_term(IsSolverType, ModuleName, VarSet, Term0,
        MaybeWhereDetails) :-
    some [!MaybeTerm] (
        !:MaybeTerm = yes(Term0),
        parse_where_attribute(parse_where_type_is_abstract_noncanonical,
            MaybeTypeIsAbstractNoncanonical, !MaybeTerm),
        parse_where_attribute(parse_where_is("representation",
                parse_where_type_is(ModuleName, VarSet)),
            MaybeRepresentationIs, !MaybeTerm),
        parse_where_attribute(parse_where_initialisation_is(ModuleName,
                VarSet),
            MaybeInitialisationIs, !MaybeTerm),
        parse_where_attribute(parse_where_is("ground",
                parse_where_inst_is(ModuleName)),
            MaybeGroundIs, !MaybeTerm),
        parse_where_attribute(parse_where_is("any",
                parse_where_inst_is(ModuleName)),
            MaybeAnyIs, !MaybeTerm),
        parse_where_attribute(parse_where_is("constraint_store",
                parse_where_mutable_is(ModuleName)),
            MaybeCStoreIs, !MaybeTerm),
        parse_where_attribute(parse_where_is("equality",
                parse_where_pred_is(ModuleName, VarSet)),
            MaybeEqualityIs, !MaybeTerm),
        parse_where_attribute(parse_where_is("comparison",
                parse_where_pred_is(ModuleName, VarSet)),
            MaybeComparisonIs, !MaybeTerm),
        parse_where_attribute(parse_where_is("direct_arg",
                parse_where_direct_arg_is(ModuleName, VarSet)),
            MaybeDirectArgIs, !MaybeTerm),
        parse_where_end(!.MaybeTerm, MaybeWhereEnd)
    ),
    MaybeWhereDetails = make_maybe_where_details(
        IsSolverType,
        MaybeTypeIsAbstractNoncanonical,
        MaybeRepresentationIs,
        MaybeInitialisationIs,
        MaybeGroundIs,
        MaybeAnyIs,
        MaybeCStoreIs,
        MaybeEqualityIs,
        MaybeComparisonIs,
        MaybeDirectArgIs,
        MaybeWhereEnd,
        Term0
    ).

    % parse_where_attribute(Parser, Result, MaybeTerm, MaybeTailTerm) handles
    % - where MaybeTerm may contain nothing
    % - where MaybeTerm may be a comma-separated pair
    % - applies Parser to the appropriate (sub)term to obtain Result
    % - sets MaybeTailTerm depending upon whether the Result is an error or not
    %   and whether there is more to parse because MaybeTerm was a
    %   comma-separated pair.
    %
:- pred parse_where_attribute((func(term) = maybe1(maybe(T)))::in,
    maybe1(maybe(T))::out, maybe(term)::in, maybe(term)::out) is det.

parse_where_attribute(Parser, Result, MaybeTerm, MaybeTailTerm) :-
    (
        MaybeTerm = no,
        MaybeTailTerm = no,
        Result = ok1(no)
    ;
        MaybeTerm = yes(Term),
        ( if
            Term = term.functor(term.atom(","), [HeadTerm, TailTerm], _)
        then
            Result = Parser(HeadTerm),
            MaybeTailTermIfYes = yes(TailTerm)
        else
            Result = Parser(Term),
            MaybeTailTermIfYes = no
        ),
        (
            Result = error1(_),
            MaybeTailTerm = no
        ;
            Result = ok1(no),
            MaybeTailTerm = yes(Term)
        ;
            Result = ok1(yes(_)),
            MaybeTailTerm = MaybeTailTermIfYes
        )
    ).

    % Parser for `where ...' attributes of the form
    % `attributename is attributevalue'.
    %
:- func parse_where_is(string, func(term) = maybe1(T), term) =
    maybe1(maybe(T)).

parse_where_is(Name, Parser, Term) = Result :-
    ( if Term = term.functor(term.atom("is"), [LHS, RHS], _) then
        ( if LHS = term.functor(term.atom(Name), [], _) then
            RHSResult = Parser(RHS),
            (
                RHSResult = ok1(ParsedRHS),
                Result    = ok1(yes(ParsedRHS))
            ;
                RHSResult = error1(Specs),
                Result    = error1(Specs)
            )
        else
            Result = ok1(no)
        )
    else
        Pieces = [words("Error: expected"), quote("is"), suffix("."), nl],
        Spec = error_spec(severity_error, phase_term_to_parse_tree,
            [simple_msg(get_term_context(Term), [always(Pieces)])]),
        Result = error1([Spec])
    ).

:- func parse_where_type_is_abstract_noncanonical(term) = maybe1(maybe(unit)).

parse_where_type_is_abstract_noncanonical(Term) =
    ( if
        Term = term.functor(term.atom("type_is_abstract_noncanonical"), [], _)
    then
        ok1(yes(unit))
    else
        ok1(no)
    ).

:- func parse_where_initialisation_is(module_name, varset, term) =
    maybe1(maybe(sym_name)).

parse_where_initialisation_is(ModuleName, VarSet, Term) = Result :-
    Result0 = parse_where_is("initialisation",
        parse_where_pred_is(ModuleName, VarSet), Term),
    ( if
        Result0 = ok1(no)
    then
        Result1 = parse_where_is("initialization",
            parse_where_pred_is(ModuleName, VarSet), Term)
    else
        Result1 = Result0
    ),
    promise_pure (
        (
            Result1 = ok1(yes(_)),
            semipure
                semipure_get_solver_auto_init_supported(AutoInitSupported),
            (
                AutoInitSupported = yes,
                Result = Result1
            ;
                AutoInitSupported = no,
                Pieces = [words("Error: unknown attribute"),
                    words("in solver type definition."), nl],
                Spec = error_spec(severity_error, phase_term_to_parse_tree,
                    [simple_msg(get_term_context(Term), [always(Pieces)])]),
                Result = error1([Spec])
            )
        ;
            ( Result1 = ok1(no)
            ; Result1 = error1(_)
            ),
            Result = Result1
        )
    ).

:- func parse_where_pred_is(module_name, varset, term) = maybe1(sym_name).

parse_where_pred_is(ModuleName, VarSet, Term) = MaybeSymName :-
    parse_implicitly_qualified_symbol_name(ModuleName, VarSet, Term,
        MaybeSymName).

:- func parse_where_inst_is(module_name, term) = maybe1(mer_inst).

parse_where_inst_is(_ModuleName, Term) = MaybeInst :-
    ( if
        convert_inst(no_allow_constrained_inst_var, Term, Inst),
        not inst_contains_unconstrained_var(Inst)
    then
        MaybeInst = ok1(Inst)
    else
        Pieces = [words("Error: expected a ground, unconstrained inst."), nl],
        Spec = error_spec(severity_error, phase_term_to_parse_tree,
            [simple_msg(get_term_context(Term), [always(Pieces)])]),
        MaybeInst = error1([Spec])
    ).

:- func parse_where_type_is(module_name, varset, term) = maybe1(mer_type).

parse_where_type_is(_ModuleName, VarSet, Term) = MaybeType :-
    % XXX We should pass meaningful ContextPieces.
    ContextPieces = [],
    parse_type(Term, VarSet, ContextPieces, MaybeType).

:- func parse_where_mutable_is(module_name, term) =
    maybe1(list(item_mutable_info)).

parse_where_mutable_is(ModuleName, Term) = MaybeItems :-
    ( if Term = term.functor(term.atom("mutable"), _, _) then
        parse_mutable_decl_term(ModuleName, Term, MaybeItem),
        (
            MaybeItem = ok1(Mutable),
            MaybeItems  = ok1([Mutable])
        ;
            MaybeItem = error1(Specs),
            MaybeItems  = error1(Specs)
        )
    else if list_term_to_term_list(Term, Terms) then
        map_parser(parse_mutable_decl_term(ModuleName), Terms, MaybeItems)
    else
        Pieces = [words("Error: expected a mutable declaration"),
            words("or a list of mutable declarations."), nl],
        Spec = error_spec(severity_error, phase_term_to_parse_tree,
            [simple_msg(get_term_context(Term), [always(Pieces)])]),
        MaybeItems = error1([Spec])
    ).

:- pred parse_mutable_decl_term(module_name::in, term::in,
    maybe1(item_mutable_info)::out) is det.

parse_mutable_decl_term(ModuleName, Term, MaybeMutableInfo) :-
    ( if
        Term = term.functor(term.atom("mutable"), Args, Context),
        varset.init(VarSet),
        parse_mutable_decl_info(ModuleName, VarSet, Args, Context, -1,
            MaybeMutableInfoPrime)
    then
        MaybeMutableInfo = MaybeMutableInfoPrime
    else
        Pieces = [words("Error: expected a mutable declaration."), nl],
        Spec = error_spec(severity_error, phase_term_to_parse_tree,
            [simple_msg(get_term_context(Term), [always(Pieces)])]),
        MaybeMutableInfo = error1([Spec])
    ).

:- func parse_where_direct_arg_is(module_name, varset, term) =
    maybe1(list(sym_name_and_arity)).

parse_where_direct_arg_is(ModuleName, VarSet, Term) = MaybeDirectArgCtors :-
    ( if list_term_to_term_list(Term, FunctorsTerms) then
        map_parser(parse_direct_arg_functor(ModuleName, VarSet),
            FunctorsTerms, MaybeDirectArgCtors)
    else
        Pieces = [words("Error: malformed functors list in"),
            quote("direct_arg"), words("attribute."), nl],
        Spec = error_spec(severity_error, phase_term_to_parse_tree,
            [simple_msg(get_term_context(Term),
            [always(Pieces)])]),
        MaybeDirectArgCtors = error1([Spec])
    ).

:- pred parse_direct_arg_functor(module_name::in, varset::in, term::in,
    maybe1(sym_name_and_arity)::out) is det.

parse_direct_arg_functor(ModuleName, VarSet, Term, MaybeFunctor) :-
    ( if parse_name_and_arity(ModuleName, Term, Name, Arity) then
        MaybeFunctor = ok1(Name / Arity)
    else
        TermStr = describe_error_term(VarSet, Term),
        Pieces = [words("Error: expected functor"),
            words("name/arity for"), quote("direct_arg"),
            words("attribute, not"), quote(TermStr), suffix("."), nl],
        Spec = error_spec(severity_error, phase_term_to_parse_tree,
            [simple_msg(get_term_context(Term), [always(Pieces)])]),
        MaybeFunctor = error1([Spec])
    ).

:- pred parse_where_end(maybe(term)::in, maybe1(maybe(unit))::out) is det.

parse_where_end(no, ok1(yes(unit))).
parse_where_end(yes(Term), error1([Spec])) :-
    Pieces = [words("Error: attributes are either badly ordered"),
        words("or contain an unrecognised attribute."), nl],
    Spec = error_spec(severity_error, phase_term_to_parse_tree,
        [simple_msg(get_term_context(Term), [always(Pieces)])]).

:- func make_maybe_where_details(is_solver_type, maybe1(maybe(unit)),
    maybe1(maybe(mer_type)), maybe1(maybe(init_pred)),
    maybe1(maybe(mer_inst)), maybe1(maybe(mer_inst)),
    maybe1(maybe(list(item_mutable_info))),
    maybe1(maybe(equality_pred)), maybe1(maybe(comparison_pred)),
    maybe1(maybe(list(sym_name_and_arity))),
    maybe1(maybe(unit)), term)
    = maybe3(maybe(solver_type_details), maybe(unify_compare),
        maybe(list(sym_name_and_arity))).

make_maybe_where_details(IsSolverType, MaybeTypeIsAbstractNoncanonical,
        MaybeRepresentationIs, MaybeInitialisationIs,
        MaybeGroundIs, MaybeAnyIs, MaybeCStoreIs,
        MaybeEqualityIs, MaybeComparisonIs, MaybeDirectArgIs,
        MaybeWhereEnd, WhereTerm) = MaybeWhereDetails :-
    ( if
        MaybeTypeIsAbstractNoncanonical = ok1(TypeIsAbstractNoncanonical),
        MaybeRepresentationIs = ok1(RepresentationIs),
        MaybeInitialisationIs = ok1(InitialisationIs),
        MaybeGroundIs = ok1(GroundIs),
        MaybeAnyIs = ok1(AnyIs),
        MaybeCStoreIs = ok1(CStoreIs),
        MaybeEqualityIs = ok1(EqualityIs),
        MaybeComparisonIs = ok1(ComparisonIs),
        MaybeDirectArgIs = ok1(DirectArgIs),
        MaybeWhereEnd = ok1(WhereEnd)
    then
        MaybeWhereDetails = make_maybe_where_details_2(IsSolverType,
            TypeIsAbstractNoncanonical, RepresentationIs, InitialisationIs,
            GroundIs, AnyIs, CStoreIs, EqualityIs, ComparisonIs, DirectArgIs,
            WhereEnd, WhereTerm)
    else
        Specs =
            get_any_errors1(MaybeTypeIsAbstractNoncanonical) ++
            get_any_errors1(MaybeRepresentationIs) ++
            get_any_errors1(MaybeInitialisationIs) ++
            get_any_errors1(MaybeGroundIs) ++
            get_any_errors1(MaybeAnyIs) ++
            get_any_errors1(MaybeCStoreIs) ++
            get_any_errors1(MaybeEqualityIs) ++
            get_any_errors1(MaybeComparisonIs) ++
            get_any_errors1(MaybeDirectArgIs) ++
            get_any_errors1(MaybeWhereEnd),
        MaybeWhereDetails = error3(Specs)
    ).

:- func make_maybe_where_details_2(is_solver_type, maybe(unit),
    maybe(mer_type), maybe(init_pred), maybe(mer_inst), maybe(mer_inst),
    maybe(list(item_mutable_info)),
    maybe(equality_pred), maybe(comparison_pred),
    maybe(list(sym_name_and_arity)), maybe(unit), term)
    = maybe3(maybe(solver_type_details), maybe(unify_compare),
        maybe(list(sym_name_and_arity))).

make_maybe_where_details_2(IsSolverType, TypeIsAbstractNoncanonical,
        RepresentationIs, InitialisationIs, GroundIs, AnyIs, CStoreIs,
        EqualityIs, ComparisonIs, DirectArgIs, _WhereEnd, WhereTerm)
        = MaybeWhereDetails :-
    (
        TypeIsAbstractNoncanonical = yes(_),
        % rafe: XXX I think this is wrong. There isn't a problem with having
        % the solver_type_details and type_is_abstract_noncanonical.
        ( if
            RepresentationIs = maybe.no,
            InitialisationIs = maybe.no,
            GroundIs         = maybe.no,
            AnyIs            = maybe.no,
            EqualityIs       = maybe.no,
            ComparisonIs     = maybe.no,
            CStoreIs         = maybe.no,
            DirectArgIs      = maybe.no
        then
            MaybeWhereDetails =
                ok3(no, yes(abstract_noncanonical_type(IsSolverType)), no)
        else
            Pieces = [words("Error:"),
                quote("where type_is_abstract_noncanonical"),
                words("excludes other"), quote("where ..."),
                words("attributes."), nl],
            Spec = error_spec(severity_error, phase_term_to_parse_tree,
                [simple_msg(get_term_context(WhereTerm), [always(Pieces)])]),
            MaybeWhereDetails = error3([Spec])
        )
    ;
        TypeIsAbstractNoncanonical = maybe.no,
        (
            IsSolverType = solver_type,
            ( if
                DirectArgIs = yes(_)
            then
                Pieces = [words("Error: solver type definitions cannot have"),
                    quote("direct_arg"), words("attributes."), nl],
                Spec = error_spec(severity_error, phase_term_to_parse_tree,
                    [simple_msg(get_term_context(WhereTerm),
                        [always(Pieces)])]),
                MaybeWhereDetails = error3([Spec])
            else if
                RepresentationIs = yes(RepnType),
                InitialisationIs = MaybeInitialisation,
                GroundIs         = MaybeGroundInst,
                AnyIs            = MaybeAnyInst,
                EqualityIs       = MaybeEqPred,
                ComparisonIs     = MaybeCmpPred,
                CStoreIs         = MaybeMutableInfos
            then
                (
                    MaybeGroundInst = yes(GroundInst)
                ;
                    MaybeGroundInst = no,
                    GroundInst = ground_inst
                ),
                (
                    MaybeAnyInst = yes(AnyInst)
                ;
                    MaybeAnyInst = no,
                    AnyInst = ground_inst
                ),
                (
                    MaybeMutableInfos = yes(MutableInfos)
                ;
                    MaybeMutableInfos = no,
                    MutableInfos = []
                ),
                (
                    MaybeInitialisation = yes(InitPred),
                    HowToInit = solver_init_automatic(InitPred)
                ;
                    MaybeInitialisation = no,
                    HowToInit = solver_init_explicit
                ),
                SolverTypeDetails = solver_type_details(
                    RepnType, HowToInit, GroundInst, AnyInst, MutableInfos),
                MaybeSolverTypeDetails = yes(SolverTypeDetails),
                ( if
                    MaybeEqPred = no,
                    MaybeCmpPred = no
                then
                    MaybeUnifyCompare = no
                else
                    MaybeUnifyCompare = yes(unify_compare(
                        MaybeEqPred, MaybeCmpPred))
                ),
                MaybeWhereDetails = ok3(MaybeSolverTypeDetails,
                    MaybeUnifyCompare, no)
            else if
                RepresentationIs = no
            then
                Pieces = [words("Error: solver type definitions must have a"),
                    quote("representation"), words("attribute."), nl],
                Spec = error_spec(severity_error, phase_term_to_parse_tree,
                    [simple_msg(get_term_context(WhereTerm),
                        [always(Pieces)])]),
                MaybeWhereDetails = error3([Spec])
            else
               unexpected($module, $pred, "make_maybe_where_details_2: " ++
                    "shouldn't have reached this point! (1)")
            )
        ;
            IsSolverType = non_solver_type,
            ( if
                ( RepresentationIs = yes(_)
                ; InitialisationIs = yes(_)
                ; GroundIs         = yes(_)
                ; AnyIs            = yes(_)
                ; CStoreIs         = yes(_)
                )
            then
                Pieces = [words("Error: solver type attribute given"),
                    words("for non-solver type."), nl],
                Spec = error_spec(severity_error, phase_term_to_parse_tree,
                    [simple_msg(get_term_context(WhereTerm),
                        [always(Pieces)])]),
                MaybeWhereDetails = error3([Spec])
            else
                MaybeUC = maybe_unify_compare(EqualityIs, ComparisonIs),
                MaybeWhereDetails = ok3(no, MaybeUC, DirectArgIs)
            )
        )
    ).

:- func maybe_unify_compare(maybe(equality_pred), maybe(comparison_pred))
    = maybe(unify_compare).

maybe_unify_compare(MaybeEqPred, MaybeCmpPred) =
    ( if
        MaybeEqPred = no,
        MaybeCmpPred = no
    then
        no
    else
        yes(unify_compare(MaybeEqPred, MaybeCmpPred))
    ).

%-----------------------------------------------------------------------------%
%
% Predicates useful for parsing several kinds of type definitions.
%

parse_type_defn_head(ModuleName, VarSet, HeadTerm, MaybeTypeCtorAndArgs) :-
    (
        HeadTerm = term.variable(_, Context),
        Pieces = [words("Error: variable on LHS of type definition."), nl],
        Spec = error_spec(severity_error, phase_term_to_parse_tree,
            [simple_msg(Context, [always(Pieces)])]),
        MaybeTypeCtorAndArgs = error2([Spec])
    ;
        HeadTerm = term.functor(_, _, HeadContext),
        ContextPieces = [words("In type definition:")],
        parse_implicitly_qualified_sym_name_and_args(ModuleName, HeadTerm,
            VarSet, ContextPieces, HeadResult),
        (
            HeadResult = error2(Specs),
            MaybeTypeCtorAndArgs = error2(Specs)
        ;
            HeadResult = ok2(SymName, ArgTerms),
            % Check that all the head args are variables.
            check_user_type_name(SymName, HeadContext, NameSpecs),
            ( if term_list_to_var_list(ArgTerms, ParamVars) then
                % Check that all the ParamVars are distinct.
                bag.from_list(ParamVars, ParamsBag),
                bag.to_list_only_duplicates(ParamsBag, DupParamVars),
                (
                    DupParamVars = [],
                    (
                        NameSpecs = [],
                        list.map(term.coerce_var, ParamVars, PrgParamVars),
                        MaybeTypeCtorAndArgs = ok2(SymName, PrgParamVars)
                    ;
                        NameSpecs = [_ | _],
                        MaybeTypeCtorAndArgs = error2(NameSpecs)
                    )
                ;
                    DupParamVars = [_ | _],
                    DupParamVarNames = list.map(
                        mercury_var_to_name_only(VarSet), DupParamVars),
                    Pieces = [words("Error: type parameters")] ++
                        list_to_pieces(DupParamVarNames) ++
                        [words("are duplicated in the LHS"),
                        words("of this type definition."), nl],
                    Spec = error_spec(severity_error, phase_term_to_parse_tree,
                        [simple_msg(HeadContext, [always(Pieces)])]),
                    MaybeTypeCtorAndArgs = error2([Spec | NameSpecs])
                )
            else
                HeadTermStr = describe_error_term(VarSet, HeadTerm),
                Pieces = [words("Error: type parameters must be variables:"),
                    words(HeadTermStr), suffix(".") ,nl],
                Spec = error_spec(severity_error, phase_term_to_parse_tree,
                    [simple_msg(HeadContext, [always(Pieces)])]),
                MaybeTypeCtorAndArgs = error2([Spec | NameSpecs])
            )
        )
    ).

    % Check that the type name is available to users.
    %
:- pred check_user_type_name(sym_name::in, term.context::in,
    list(error_spec)::out) is det.

check_user_type_name(SymName, Context, NameSpecs) :-
    % Check that the mode name is available to users.
    Name = unqualify_name(SymName),
    ( if is_known_type_name(Name) then
        NamePieces = [words("Error: the type name"), quote(Name),
            words("is reserved for the Mercury implementation."), nl],
        NameSpec = error_spec(severity_error, phase_term_to_parse_tree,
            [simple_msg(Context, [always(NamePieces)])]),
        NameSpecs = [NameSpec]
    else
        NameSpecs = []
    ).

    % Check that all the variables in the body occur in the head.
    % Return a nonempty list of error specs if some do.
    %
:- pred check_no_free_body_vars(tvarset::in, list(tvar)::in, mer_type::in,
    prog_context::in, list(error_spec)::out) is det.

check_no_free_body_vars(TVarSet, ParamTVars, BodyType, BodyContext, Specs) :-
    % Check that all the variables in the body occur in the head.
    type_vars(BodyType, BodyTVars),
    set.list_to_set(ParamTVars, ParamTVarSet),
    set.list_to_set(BodyTVars, BodyTVarSet),
    set.difference(BodyTVarSet, ParamTVarSet, OnlyBodyTVarSet),
    set.to_sorted_list(OnlyBodyTVarSet, OnlyBodyTVars),
    (
        OnlyBodyTVars = [],
        Specs = []
    ;
        OnlyBodyTVars = [_ | _],
        OnlyBodyTVarNames = list.map(mercury_var_to_name_only(TVarSet),
            OnlyBodyTVars),
        VarWord = choose_number(OnlyBodyTVars,
            "the type variable", "the type variables"),
        OccurWord = choose_number(OnlyBodyTVars,
            "occurs", "occur"),
        Pieces = [words("Error:"), words(VarWord)] ++
            list_to_pieces(OnlyBodyTVarNames) ++ [words(OccurWord),
            words("only in the RHS of this type definition."), nl],
        Spec = error_spec(severity_error, phase_term_to_parse_tree,
            [simple_msg(BodyContext, [always(Pieces)])]),
        Specs = [Spec]
    ).

%-----------------------------------------------------------------------------e

:- pred get_is_solver_type(is_solver_type::out,
    decl_attrs::in, decl_attrs::out) is det.

get_is_solver_type(IsSolverType, !Attributes) :-
    ( if !.Attributes = [decl_attr_solver_type - _ | !:Attributes] then
        IsSolverType = solver_type
    else
        IsSolverType = non_solver_type
    ).

%-----------------------------------------------------------------------------e
:- end_module parse_tree.prog_io_type_defn.
%-----------------------------------------------------------------------------e
