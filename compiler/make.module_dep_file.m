%-----------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 expandtab
%-----------------------------------------------------------------------------%
% Copyright (C) 2002-2009, 2011 The University of Melbourne.
% Copyright (C) 2014-2017, 2019-2020 The Mercury team.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%-----------------------------------------------------------------------------%
%
% File: make.module_dep_file.m.
% Author: stayl.
%
% Code to read and write the `<module>.module_dep' files, which contain
% information about inter-module dependencies.
%
%-----------------------------------------------------------------------------%

:- module make.module_dep_file.
:- interface.

:- import_module libs.
:- import_module libs.globals.
:- import_module mdbcomp.
:- import_module mdbcomp.sym_name.

:- import_module io.
:- import_module maybe.

%-----------------------------------------------------------------------------%

    % Get the dependencies for a given module.
    % Dependencies are generated on demand, not by a `mmc --make depend'
    % command, so this predicate may need to read the source for the module.
    %
:- pred get_module_dependencies(globals::in, module_name::in,
    maybe_module_dep_info::out, make_info::in, make_info::out,
    io::di, io::uo) is det.

:- pred write_module_dep_file(globals::in, module_and_imports::in,
    io::di, io::uo) is det.

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- implementation.

:- import_module libs.file_util.
:- import_module libs.process_util.
:- import_module parse_tree.
:- import_module parse_tree.error_util.
:- import_module parse_tree.file_names.
:- import_module parse_tree.get_dependencies.
:- import_module parse_tree.item_util.
:- import_module parse_tree.mercury_to_mercury.
:- import_module parse_tree.parse_error.
:- import_module parse_tree.parse_sym_name.
:- import_module parse_tree.prog_data_foreign.
:- import_module parse_tree.prog_item.
:- import_module parse_tree.prog_out.
:- import_module parse_tree.read_modules.
:- import_module parse_tree.write_module_interface_files.

:- import_module dir.
:- import_module getopt.
:- import_module parser.
:- import_module term.
:- import_module term_io.

    % The version 1 module_dep file format is the same as version 2 except that
    % it does not include a list of files included by `pragma foreign_decl' and
    % `pragma foreign_code'. We continue to write version 1 files when
    % possible.
    %
    % XXX We should consider
    %
    % - adding a version 3 that differs from 2 in deleting the field
    %   that now *always* contains "no_main", and
    % - switching to always generating version 3.
    %
    % XXX The precise on-disk representation of each (current) module_dep file
    % format version should be explicitly documented. This documentation
    % should explain what the meaning of each field is, what purposes
    % does it servce, an what invariants (if any) apply to it. It should
    % also have some examples to help readers understand it all.
    %
:- type module_dep_file_version
    --->    module_dep_file_v1
    ;       module_dep_file_v2.

:- pred version_number(module_dep_file_version, int).
:- mode version_number(in, out) is det.
:- mode version_number(out, in) is semidet.

version_number(module_dep_file_v1, 1).
version_number(module_dep_file_v2, 2).

%-----------------------------------------------------------------------------%

get_module_dependencies(Globals, ModuleName, MaybeModuleDepInfo, !Info, !IO) :-
    RebuildModuleDeps = !.Info ^ rebuild_module_deps,
    (
        ModuleName = unqualified(_),
        maybe_get_module_dependencies(Globals, RebuildModuleDeps, ModuleName,
            MaybeModuleDepInfo, !Info, !IO)
    ;
        ModuleName = qualified(_, _),
        % For submodules, we need to generate the dependencies for the
        % parent modules first (make_module_dependencies expects to be given
        % the top-level module in a source file).
        % If the module is a nested module, its dependencies will be generated
        % as a side effect of generating the parent's dependencies.
        AncestorsAndSelf = get_ancestors(ModuleName) ++ [ModuleName],
        Error0 = no,
        maybe_get_modules_dependencies(Globals, RebuildModuleDeps,
            AncestorsAndSelf, Error0, !Info, !IO),

        ModuleDepMap = !.Info ^ module_dependencies,
        map.lookup(ModuleDepMap, ModuleName, MaybeModuleDepInfo)
    ).

:- pred maybe_get_modules_dependencies(globals::in, rebuild_module_deps::in,
    list(module_name)::in, bool::in, make_info::in, make_info::out,
    io::di, io::uo) is det.

maybe_get_modules_dependencies(_Globals, _RebuildModuleDeps,
        [], _, !Info, !IO).
maybe_get_modules_dependencies(Globals, RebuildModuleDeps,
        [ModuleName | ModuleNames], !.Error, !Info, !IO) :-
    (
        !.Error = no,
        maybe_get_module_dependencies(Globals, RebuildModuleDeps, ModuleName,
            MaybeModuleDepInfo, !Info, !IO),
        (
            MaybeModuleDepInfo = some_module_dep_info(_)
        ;
            MaybeModuleDepInfo = no_module_dep_info,
            !:Error = yes
        )
    ;
        !.Error = yes,
        % If we found a problem when processing an ancestor, don't even try
        % to process the later modules.
        ModuleDepMap0 = !.Info ^ module_dependencies,
        % XXX Could this be map.det_update or map.det_insert?
        map.set(ModuleName, no_module_dep_info, ModuleDepMap0, ModuleDepMap),
        !Info ^ module_dependencies := ModuleDepMap
    ),
    maybe_get_modules_dependencies(Globals, RebuildModuleDeps,
        ModuleNames, !.Error, !Info, !IO).

:- pred maybe_get_module_dependencies(globals::in, rebuild_module_deps::in,
    module_name::in, maybe_module_dep_info::out,
    make_info::in, make_info::out, io::di, io::uo) is det.

maybe_get_module_dependencies(Globals, RebuildModuleDeps, ModuleName,
        MaybeModuleDepInfo, !Info, !IO) :-
    ModuleDepMap0 = !.Info ^ module_dependencies,
    ( if map.search(ModuleDepMap0, ModuleName, MaybeModuleDepInfo0) then
        MaybeModuleDepInfo = MaybeModuleDepInfo0
    else
        do_get_module_dependencies(Globals, RebuildModuleDeps, ModuleName,
            MaybeModuleDepInfo, !Info, !IO)
    ).

:- pred do_get_module_dependencies(globals::in, rebuild_module_deps::in,
    module_name::in, maybe_module_dep_info::out,
    make_info::in, make_info::out, io::di, io::uo) is det.

do_get_module_dependencies(Globals, RebuildModuleDeps, ModuleName,
        !:MaybeModuleDepInfo, !Info, !IO) :-
    % We can't just use
    %   `get_target_timestamp(ModuleName - source, ..)'
    % because that could recursively call get_module_dependencies,
    % leading to an infinite loop. Just using module_name_to_file_name
    % will fail if the module name doesn't match the file name, but
    % that case is handled below.
    module_name_to_source_file_name(ModuleName, SourceFileName, !IO),
    get_file_timestamp([dir.this_directory], SourceFileName,
        MaybeSourceFileTimestamp, !Info, !IO),

    module_name_to_file_name(Globals, $pred, do_not_create_dirs,
        ext_other(make_module_dep_file_extension),
        ModuleName, DepFileName, !IO),
    globals.lookup_accumulating_option(Globals, search_directories,
        SearchDirs),
    get_file_timestamp(SearchDirs, DepFileName, MaybeDepFileTimestamp,
        !Info, !IO),
    (
        MaybeSourceFileTimestamp = ok(SourceFileTimestamp),
        MaybeDepFileTimestamp = ok(DepFileTimestamp),
        ( if
            ( RebuildModuleDeps = do_not_rebuild_module_deps
            ; compare((>), DepFileTimestamp, SourceFileTimestamp)
            )
        then
            % Since the source file was found in this directory, do not use
            % module_dep files which might be for installed copies
            % of the module.
            %
            % XXX SourceFileName may not actually be the correct source file
            % for the required module. Usually the purported source file would
            % have a later timestamp than the .module_dep file, though, so the
            % other branch would be taken.
            read_module_dependencies_no_search(Globals, RebuildModuleDeps,
                ModuleName, !Info, !IO)
        else
            make_module_dependencies(Globals, ModuleName, !Info, !IO)
        )
    ;
        MaybeSourceFileTimestamp = error(_),
        MaybeDepFileTimestamp = ok(DepFileTimestamp),
        read_module_dependencies_search(Globals, RebuildModuleDeps,
            ModuleName, !Info, !IO),

        % Check for the case where the module name doesn't match the
        % source file name (e.g. parse.m contains module mdb.parse).
        % Get the correct source file name from the module dependency file,
        % then check whether the module dependency file is up to date.

        map.lookup(!.Info ^ module_dependencies, ModuleName,
            !:MaybeModuleDepInfo),
        ( if
            !.MaybeModuleDepInfo = some_module_dep_info(ModuleDepInfo0),
            module_dep_info_get_source_file_dir(ModuleDepInfo0, ModuleDir),
            ModuleDir = dir.this_directory
        then
            module_dep_info_get_source_file_name(ModuleDepInfo0,
                SourceFileName1),
            get_file_timestamp([dir.this_directory], SourceFileName1,
                MaybeSourceFileTimestamp1, !Info, !IO),
            (
                MaybeSourceFileTimestamp1 = ok(SourceFileTimestamp1),
                ( if
                    ( RebuildModuleDeps = do_not_rebuild_module_deps
                    ; compare((>), DepFileTimestamp, SourceFileTimestamp1)
                    )
                then
                    true
                else
                    % XXX The existence of a .module_dep file reflects a
                    % previous state of the workspace which may not match the
                    % current workspace.
                    %
                    % Here is a (contrived) case where we run into an issue:
                    % 1. create prog.m which imports the standard library lexer
                    %    module
                    % 2. copy the standard library lexer.m file to the current
                    %    directory for editing
                    % 3. run mmc --make; it creates lexer.module_dep
                    % 4. change lexer.m into a submodule of prog
                    % 5. run mmc --make again, it no longer works
                    %
                    % The local lexer.module_dep prevents mmc --make finding
                    % the lexer.module_dep from the standard library, even
                    % though there is no longer any local source file for the
                    % `lexer' module.

                    make_module_dependencies(Globals, ModuleName, !Info, !IO)
                )
            ;
                MaybeSourceFileTimestamp1 = error(Message),
                io.format("** Error reading file `%s' " ++
                    "to generate dependencies: %s.\n",
                    [s(SourceFileName1), s(Message)], !IO),
                maybe_write_importing_module(ModuleName,
                    !.Info ^ importing_module, !IO)
            )
        else
            true
        )
    ;
        MaybeDepFileTimestamp = error(_),
        SearchDirsString = join_list(", ",
            map((func(Dir) = "`" ++ Dir ++ "'"), SearchDirs)),
        debug_make_msg(Globals,
            io.format(
                "Module dependencies file '%s' not found in directories %s.\n",
                [s(DepFileName), s(SearchDirsString)]),
            !IO),

        % Try to make the dependencies. This will succeed when the module name
        % doesn't match the file name and the dependencies for this module
        % haven't been built before. It will fail if the source file
        % is in another directory.
        (
            RebuildModuleDeps = do_rebuild_module_deps,
            make_module_dependencies(Globals, ModuleName, !Info, !IO)
        ;
            RebuildModuleDeps = do_not_rebuild_module_deps,
            ModuleDepMap0 = !.Info ^ module_dependencies,
            % XXX Could this be map.det_update or map.det_insert?
            map.set(ModuleName, no_module_dep_info,
                ModuleDepMap0, ModuleDepMap1),
            !Info ^ module_dependencies := ModuleDepMap1
        )
    ),
    ModuleDepMap2 = !.Info ^ module_dependencies,
    ( if map.search(ModuleDepMap2, ModuleName, MaybeModuleDepInfo0) then
        !:MaybeModuleDepInfo = MaybeModuleDepInfo0
    else
        !:MaybeModuleDepInfo = no_module_dep_info,
        map.det_insert(ModuleName, no_module_dep_info,
            ModuleDepMap2, ModuleDepMap),
        !Info ^ module_dependencies := ModuleDepMap
    ).

%-----------------------------------------------------------------------------%

write_module_dep_file(Globals, ModuleAndImports0, !IO) :-
    rebuild_module_and_imports_for_dep_file(Globals,
        ModuleAndImports0, ModuleAndImports),
    do_write_module_dep_file(Globals, ModuleAndImports, !IO).

:- pred do_write_module_dep_file(globals::in, module_and_imports::in,
    io::di, io::uo) is det.

do_write_module_dep_file(Globals, ModuleAndImports, !IO) :-
    module_and_imports_get_module_name(ModuleAndImports, ModuleName),
    module_name_to_file_name(Globals, $pred, do_create_dirs,
        ext_other(make_module_dep_file_extension),
        ModuleName, ProgDepFile, !IO),
    io.open_output(ProgDepFile, ProgDepResult, !IO),
    (
        ProgDepResult = ok(ProgDepStream),
        do_write_module_dep_file_to_stream(ProgDepStream, Globals,
            ModuleAndImports, !IO),
        io.close_output(ProgDepStream, !IO)
    ;
        ProgDepResult = error(Error),
        io.error_message(Error, Msg),
        io.format("Error opening %s for output: %s\n",
            [s(ProgDepFile), s(Msg)], !IO),
        io.set_exit_status(1, !IO)
    ).

:- pred do_write_module_dep_file_to_stream(io.text_output_stream::in,
    globals::in, module_and_imports::in, io::di, io::uo) is det.

do_write_module_dep_file_to_stream(Stream, Globals, ModuleAndImports, !IO) :-
    Version = module_dep_file_v2,
    version_number(Version, VersionNumber),
    module_and_imports_get_source_file_name(ModuleAndImports, SourceFileName),
    module_and_imports_get_source_file_module_name(ModuleAndImports,
        SourceFileModuleName),
    SourceFileModuleNameStr =
        mercury_bracketed_sym_name_to_string(SourceFileModuleName),
    module_and_imports_get_module_name(ModuleAndImports, ModuleName),
    Ancestors = set.to_sorted_list(get_ancestors_set(ModuleName)),
    module_and_imports_get_int_deps(ModuleAndImports, IntDeps),
    module_and_imports_get_imp_deps(ModuleAndImports, ImpDeps),
    module_and_imports_get_children(ModuleAndImports, Children),
    module_and_imports_get_maybe_top_module(ModuleAndImports, MaybeTopModule),
    NestedSubModules = get_nested_children_list_of_top_module(MaybeTopModule),
    module_and_imports_get_fact_tables(ModuleAndImports, FactTableFilesSet),
    FactTableFiles = set.to_sorted_list(FactTableFilesSet),
    module_and_imports_get_parse_tree_module_src(ModuleAndImports,
        ParseTreeModuleSrc),
    globals.get_backend_foreign_languages(Globals, BackendLangsList),
    BackendLangs = set.list_to_set(BackendLangsList), 
    get_foreign_code_langs(ParseTreeModuleSrc, CodeLangs),
    get_foreign_export_langs(ParseTreeModuleSrc, ExportLangs),
    set.intersect(BackendLangs, CodeLangs, BackendCodeLangs),
    set.intersect(BackendLangs, ExportLangs, BackendExportLangs),
    CodeLangStrs = list.map(mercury_foreign_language_to_string,
        set.to_sorted_list(BackendCodeLangs)),
    ( if set.is_empty(BackendExportLangs) then
        ContainsForeignExport = contains_no_foreign_export
    else
        ContainsForeignExport = contains_foreign_export
    ),
    get_fims(ParseTreeModuleSrc, FIMSpecs),
    get_foreign_include_file_infos(ParseTreeModuleSrc, ForeignIncludeFiles),
    FIMSpecStrs = list.map(fim_spec_to_string, set.to_sorted_list(FIMSpecs)),
    FIFOStrs = list.map(foreign_include_file_info_to_string,
        set.to_sorted_list(ForeignIncludeFiles)),
    contains_foreign_export_to_string(ContainsForeignExport,
        ContainsForeignExportStr),
    io.format(Stream,
        "module(%d, ""%s"",\n" ++
            "\t%s,\n" ++
            "\t{%s},\n" ++
            "\t{%s},\n" ++
            "\t{%s},\n" ++
            "\t{%s},\n" ++
            "\t{%s},\n" ++
            "\t{%s},\n" ++
            "\t{%s},\n" ++
            "\t{%s},\n" ++
            "\t%s,\n" ++
            % The has_main/no_main slot is not needed anymore,
            % so we just put no_main in there always.
            "\tno_main,\n" ++
            "\t{%s}\n" ++
        ").\n",
        [i(VersionNumber), s(SourceFileName),
        s(SourceFileModuleNameStr),
        s(bracketed_sym_names_to_comma_list_string(Ancestors)),
        s(bracketed_sym_names_to_comma_list_string(IntDeps)),
        s(bracketed_sym_names_to_comma_list_string(ImpDeps)),
        s(bracketed_sym_names_to_comma_list_string(Children)),
        s(bracketed_sym_names_to_comma_list_string(NestedSubModules)),
        s(string.join_list(", ", FactTableFiles)),
        s(string.join_list(", ", CodeLangStrs)),
        s(string.join_list(", ", FIMSpecStrs)),
        s(ContainsForeignExportStr),
        s(string.join_list(", ", FIFOStrs))],
        !IO).

:- func bracketed_sym_names_to_comma_list_string(list(sym_name)) = string.

bracketed_sym_names_to_comma_list_string(SymNames) = Str :-
    Strs = list.map(mercury_bracketed_sym_name_to_string, SymNames),
    Str = string.join_list(", ", Strs).

:- func fim_spec_to_string(fim_spec) = string.

fim_spec_to_string(FIMSpec) = Str :-
    FIMSpec = fim_spec(Lang, ForeignImport),
    LangStr = mercury_foreign_language_to_string(Lang),
    ForeignImportStr = mercury_bracketed_sym_name_to_string(ForeignImport),
    Str = LangStr ++ " - " ++ ForeignImportStr.

:- func foreign_include_file_info_to_string(foreign_include_file_info)
    = string.

foreign_include_file_info_to_string(ForeignInclude) = Str :-
    ForeignInclude = foreign_include_file_info(Lang, FileName),
    LangStr = mercury_foreign_language_to_string(Lang),
    Str = LangStr ++ " - " ++ term_io.quoted_string(FileName).

:- pred contains_foreign_export_to_string(contains_foreign_export, string).
:- mode contains_foreign_export_to_string(in, out) is det.
:- mode contains_foreign_export_to_string(out, in) is semidet.

contains_foreign_export_to_string(ContainsForeignExport,
        ContainsForeignExportStr) :-
    (
        ContainsForeignExport = contains_foreign_export,
        ContainsForeignExportStr = "contains_foreign_export"
    ;
        ContainsForeignExport = contains_no_foreign_export,
        % Yes, without the "contains_" prefix. Don't change it unless you mean
        % to break compatibility with older .module_dep files.
        ContainsForeignExportStr = "no_foreign_export"
    ).

%-----------------------------------------------------------------------------%

:- pred read_module_dependencies_search(globals::in, rebuild_module_deps::in,
    module_name::in, make_info::in, make_info::out, io::di, io::uo) is det.

read_module_dependencies_search(Globals, RebuildModuleDeps, ModuleName,
        !Info, !IO) :-
    globals.lookup_accumulating_option(Globals, search_directories,
        SearchDirs),
    read_module_dependencies_2(Globals, RebuildModuleDeps, SearchDirs,
        ModuleName, !Info, !IO).

:- pred read_module_dependencies_no_search(globals::in,
    rebuild_module_deps::in, module_name::in, make_info::in, make_info::out,
    io::di, io::uo) is det.

read_module_dependencies_no_search(Globals, RebuildModuleDeps, ModuleName,
        !Info, !IO) :-
    read_module_dependencies_2(Globals, RebuildModuleDeps,
        [dir.this_directory], ModuleName, !Info, !IO).

:- pred read_module_dependencies_2(globals::in, rebuild_module_deps::in,
    list(dir_name)::in, module_name::in, make_info::in, make_info::out,
    io::di, io::uo) is det.

read_module_dependencies_2(Globals, RebuildModuleDeps, SearchDirs, ModuleName,
        !Info, !IO) :-
    module_name_to_search_file_name(Globals, $pred,
        ext_other(make_module_dep_file_extension),
        ModuleName, ModuleDepFile, !IO),
    search_for_file_returning_dir_and_stream(SearchDirs, ModuleDepFile,
        MaybeDirAndStream, !IO),
    (
        MaybeDirAndStream = ok(path_name_and_stream(ModuleDir, DepStream)),
        parser.read_term(DepStream, TermResult, !IO),
        io.close_input(DepStream, !IO),
        (
            TermResult = term(_, Term),
            read_module_dependencies_3(Globals, SearchDirs, ModuleName,
                ModuleDir, ModuleDepFile, Term, Result, !Info, !IO)
        ;
            TermResult = eof,
            Result = error("unexpected eof")
        ;
            TermResult = error(ParseError, _),
            Result = error("parse error: " ++ ParseError)
        ),
        (
            Result = ok
        ;
            Result = error(Msg),
            read_module_dependencies_remake_msg(RebuildModuleDeps,
                ModuleDir ++ "/" ++ ModuleDepFile, Msg, !IO),
            read_module_dependencies_remake(Globals, RebuildModuleDeps,
                ModuleName, !Info, !IO)
        )
    ;
        MaybeDirAndStream = error(Msg),
        debug_make_msg(Globals,
            read_module_dependencies_remake_msg(RebuildModuleDeps,
                ModuleDepFile, Msg),
            !IO),
        read_module_dependencies_remake(Globals, RebuildModuleDeps,
            ModuleName, !Info, !IO)
    ).

:- pred read_module_dependencies_3(globals::in, list(dir_name)::in,
    module_name::in, dir_name::in, file_name::in, term::in, maybe_error::out,
    make_info::in, make_info::out, io::di, io::uo) is det.

read_module_dependencies_3(Globals, SearchDirs, ModuleName, ModuleDir,
        ModuleDepFile, Term, Result, !Info, !IO) :-
    ( if
        atom_term(Term, "module", ModuleArgs),
        ModuleArgs = [
            VersionNumberTerm,
            SourceFileTerm,
            SourceFileModuleNameTerm,
            ParentsTerm,                % XXX Redundant term
            IntDepsTerm,
            ImpDepsTerm,
            ChildrenTerm,
            NestedSubModulesTerm,
            FactDepsTerm,
            ForeignLanguagesTerm,
            ForeignImportsTerm,
            ContainsForeignExportTerm,
            _HasMainTerm
            | ModuleArgsTail
        ],

        version_number_term(VersionNumberTerm, Version),
        string_term(SourceFileTerm, SourceFileName),
        try_parse_sym_name_and_no_args(SourceFileModuleNameTerm,
            SourceFileModuleName),

        sym_names_term(ParentsTerm, Parents),
        sym_names_term(IntDepsTerm, IntDeps),
        sym_names_term(ImpDepsTerm, ImpDeps),
        sym_names_term(ChildrenTerm, Children),
        sym_names_term(NestedSubModulesTerm, NestedSubModules0),

        braces_term(fact_dep_term, FactDepsTerm, FactDeps),
        braces_term(foreign_language_term, ForeignLanguagesTerm,
            ForeignLanguages),
        braces_term(foreign_import_term, ForeignImportsTerm, ForeignImports),

        contains_foreign_export_term(ContainsForeignExportTerm,
            ContainsForeignExport),

        (
            Version = module_dep_file_v1,
            ModuleArgsTail = [],
            ForeignIncludes = []
        ;
            Version = module_dep_file_v2,
            ModuleArgsTail = [ForeignIncludesTerm],
            braces_term(foreign_include_term, ForeignIncludesTerm,
                ForeignIncludes)
        )
    then
        ( if ModuleName = SourceFileModuleName then
            MaybeTopModule = top_module(set.list_to_set(NestedSubModules0))
        else
            MaybeTopModule = not_top_module,
            expect(unify(NestedSubModules0, []), $pred,
                "NestedSubModules0 != []")
        ),
        set.list_to_set(Parents, ParentsSet),
        AncestorsSet = get_ancestors_set(ModuleName),
        expect(set.equal(ParentsSet, AncestorsSet), $pred,
            "ParentsSet != AncestorsSet"),
        ContainsForeignCode =
            foreign_code_langs_known(set.list_to_set(ForeignLanguages)),
        ModuleSummary = module_dep_summary(SourceFileName, ModuleDir,
            SourceFileModuleName, ModuleName, set.list_to_set(Children),
            MaybeTopModule,
            set.list_to_set(IntDeps), set.list_to_set(ImpDeps),
            set.list_to_set(FactDeps), set.list_to_set(ForeignImports),
            set.list_to_set(ForeignIncludes),
            ContainsForeignCode, ContainsForeignExport),
        ModuleDepInfo = module_dep_info_summary(ModuleSummary),
        MaybeModuleDepInfo = some_module_dep_info(ModuleDepInfo),

        % Discard the module dependencies if the module is a local module
        % but the source file no longer exists.
        ( if ModuleDir = dir.this_directory then
            check_regular_file_exists(SourceFileName, SourceFileExists, !IO),
            (
                SourceFileExists = ok
            ;
                SourceFileExists = error(_),
                io.remove_file(ModuleDepFile, _, !IO)
            )
        else
            SourceFileExists = ok
        ),
        (
            SourceFileExists = ok,
            ModuleDepMap0 = !.Info ^ module_dependencies,
            % XXX Could this be map.det_insert?
            map.set(ModuleName, MaybeModuleDepInfo,
                ModuleDepMap0, ModuleDepMap),
            !Info ^ module_dependencies := ModuleDepMap,

            % Read the dependencies for any nested children. If something
            % goes wrong (for example one of the files was removed), the
            % dependencies for all modules in the source file will be remade
            % (make_module_dependencies expects to be given the top-level
            % module in the source file).
            NestedSubModules =
                get_nested_children_list_of_top_module(MaybeTopModule),
            list.foldl2(
                read_module_dependencies_2(Globals,
                    do_not_rebuild_module_deps, SearchDirs),
                NestedSubModules, !Info, !IO),
            ( if some_bad_module_dependency(!.Info, NestedSubModules0) then
                Result = error("error in nested submodules")
            else
                Result = ok
            )
        ;
            SourceFileExists = error(Error),
            Result = error(Error)
        )
    else
        Result = error("failed to parse term")
    ).

:- pred version_number_term(term::in, module_dep_file_version::out) is semidet.

version_number_term(Term, Version) :-
    decimal_term_to_int(Term, Int),
    version_number(Version, Int).

:- pred string_term(term::in, string::out) is semidet.

string_term(Term, String) :-
    Term = term.functor(term.string(String), [], _).

:- pred atom_term(term::in, string::out, list(term)::out) is semidet.

atom_term(Term, Atom, Args) :-
    Term = term.functor(term.atom(Atom), Args, _).

:- pred braces_term(pred(term, U), term, list(U)).
:- mode braces_term(in(pred(in, out) is semidet), in, out) is semidet.

braces_term(P, Term, Args) :-
    atom_term(Term, "{}", ArgTerms),
    list.map(P, ArgTerms, Args).

:- pred sym_names_term(term::in, list(sym_name)::out) is semidet.

sym_names_term(Term, SymNames) :-
    braces_term(try_parse_sym_name_and_no_args, Term, SymNames).

:- pred fact_dep_term(term::in, string::out) is semidet.

fact_dep_term(Term, FactDep) :-
    string_term(Term, FactDep).

:- pred foreign_language_term(term::in, foreign_language::out) is semidet.

foreign_language_term(Term, Lang) :-
    string_term(Term, String),
    globals.convert_foreign_language(String, Lang).

:- pred foreign_import_term(term::in, fim_spec::out) is semidet.

foreign_import_term(Term, FIMSpec) :-
    atom_term(Term, "-", [LanguageTerm, ImportedModuleTerm]),
    foreign_language_term(LanguageTerm, Language),
    try_parse_sym_name_and_no_args(ImportedModuleTerm, ImportedModuleName),
    FIMSpec = fim_spec(Language, ImportedModuleName).

:- pred foreign_include_term(term::in, foreign_include_file_info::out)
    is semidet.

foreign_include_term(Term, ForeignInclude) :-
    atom_term(Term, "-", [LanguageTerm, FileNameTerm]),
    foreign_language_term(LanguageTerm, Language),
    string_term(FileNameTerm, FileName),
    ForeignInclude = foreign_include_file_info(Language, FileName).

:- pred contains_foreign_export_term(term::in, contains_foreign_export::out)
    is semidet.

contains_foreign_export_term(Term, ContainsForeignExport) :-
    atom_term(Term, Atom, []),
    contains_foreign_export_to_string(ContainsForeignExport, Atom).

:- pred some_bad_module_dependency(make_info::in, list(module_name)::in)
    is semidet.

some_bad_module_dependency(Info, ModuleNames) :-
    list.member(ModuleName, ModuleNames),
    map.search(Info ^ module_dependencies, ModuleName, no_module_dep_info).

:- pred check_regular_file_exists(file_name::in, maybe_error::out,
    io::di, io::uo) is det.

check_regular_file_exists(FileName, FileExists, !IO) :-
    FollowSymLinks = yes,
    io.file_type(FollowSymLinks, FileName, ResFileType, !IO),
    (
        ResFileType = ok(FileType),
        (
            ( FileType = regular_file
            ; FileType = unknown
            ),
            FileExists = ok
        ;
            ( FileType = directory
            ; FileType = symbolic_link
            ; FileType = named_pipe
            ; FileType = socket
            ; FileType = character_device
            ; FileType = block_device
            ; FileType = message_queue
            ; FileType = semaphore
            ; FileType = shared_memory
            ),
            FileExists = error(FileName ++ ": not a regular file")
        )
    ;
        ResFileType = error(Error),
        FileExists = error(FileName ++ ": " ++ io.error_message(Error))
    ).

%-----------------------------------------------------------------------------%

    % Something went wrong reading the dependencies, so just rebuild them.
    %
:- pred read_module_dependencies_remake(globals::in, rebuild_module_deps::in,
    module_name::in, make_info::in, make_info::out,
    io::di, io::uo) is det.

read_module_dependencies_remake(Globals, RebuildModuleDeps, ModuleName,
        !Info, !IO) :-
    (
        RebuildModuleDeps = do_rebuild_module_deps,
        make_module_dependencies(Globals, ModuleName, !Info, !IO)
    ;
        RebuildModuleDeps = do_not_rebuild_module_deps
    ).

:- pred read_module_dependencies_remake_msg(rebuild_module_deps::in,
    string::in, string::in, io::di, io::uo) is det.

read_module_dependencies_remake_msg(RebuildModuleDeps, ModuleDepsFile, Msg,
        !IO) :-
    io.format("** Error reading file `%s': %s", [s(ModuleDepsFile), s(Msg)],
        !IO),
    (
        RebuildModuleDeps = do_rebuild_module_deps,
        io.write_string(" ...rebuilding\n", !IO)
    ;
        RebuildModuleDeps = do_not_rebuild_module_deps,
        io.nl(!IO)
    ).

    % The module_name given must be the top level module in the source file.
    % get_module_dependencies ensures this by making the dependencies
    % for all parent modules of the requested module first.
    %
:- pred make_module_dependencies(globals::in, module_name::in,
    make_info::in, make_info::out, io::di, io::uo) is det.

make_module_dependencies(Globals, ModuleName, !Info, !IO) :-
    prepare_to_redirect_output(ModuleName, MaybeErrorStream, !Info, !IO),
    (
        MaybeErrorStream = yes(ErrorStream),
        io.set_output_stream(ErrorStream, OldOutputStream, !IO),
        % XXX Why ask for the timestamp if we then ignore it?
        read_module_src(Globals, "Getting dependencies for module",
            do_not_ignore_errors, do_not_search, ModuleName, [],
            SourceFileName, always_read_module(do_return_timestamp), _,
            ParseTreeSrc, Specs0, ReadModuleErrors, !IO),

        set.intersect(ReadModuleErrors, fatal_read_module_errors, FatalErrors),
        ( if set.is_non_empty(FatalErrors) then
            FatalReadError = yes,
            DisplayErrorReadingFile = yes
        else if set.contains(ReadModuleErrors, rme_unexpected_module_name) then
            % If the source file does not contain the expected module, then
            % do not make the .module_dep file; it would leave a .module_dep
            % file for the wrong module lying around, which the user needs
            % to delete manually.
            FatalReadError = yes,
            DisplayErrorReadingFile = no
        else
            FatalReadError = no,
            DisplayErrorReadingFile = no
        ),
        (
            FatalReadError = yes,
            write_error_specs_ignore(ErrorStream, Globals, Specs0, !IO),
            io.set_output_stream(OldOutputStream, _, !IO),
            (
                DisplayErrorReadingFile = yes,
                io.format(
                    "** Error reading file `%s' to generate dependencies.\n",
                    [s(SourceFileName)], !IO),
                maybe_write_importing_module(ModuleName,
                    !.Info ^ importing_module, !IO)
            ;
                DisplayErrorReadingFile = no
            ),

            % Display the contents of the `.err' file, then remove it
            % so we don't leave `.err' files lying around for nonexistent
            % modules.
            globals.set_option(output_compile_error_lines, int(10000),
                Globals, UnredirectGlobals),
            unredirect_output(UnredirectGlobals, ModuleName, ErrorStream,
                !Info, !IO),
            module_name_to_file_name(Globals, $pred, do_not_create_dirs,
                ext_other(other_ext(".err")), ModuleName, ErrFileName, !IO),
            io.remove_file(ErrFileName, _, !IO),

            ModuleDepMap0 = !.Info ^ module_dependencies,
            % XXX Could this be map.det_update?
            map.set(ModuleName, no_module_dep_info,
                ModuleDepMap0, ModuleDepMap),
            !Info ^ module_dependencies := ModuleDepMap
        ;
            FatalReadError = no,
            parse_tree_src_to_module_and_imports_list(Globals, SourceFileName,
                ParseTreeSrc, ReadModuleErrors, Specs0, Specs,
                ParseTreeModuleSrcs, ModuleAndImportsList),
            SubModuleNames = list.map(parse_tree_module_src_project_name,
                 ParseTreeModuleSrcs),

            io.set_output_stream(ErrorStream, _, !IO),
            % XXX Why are we ignoring all previously reported errors?
            io.set_exit_status(0, !IO),
            write_error_specs_ignore(Globals, Specs, !IO),
            io.set_output_stream(OldOutputStream, _, !IO),

            list.foldl(make_info_add_module_and_imports_as_dep,
                ModuleAndImportsList, !Info),

            % If there were no errors, write out the `.int3' file
            % while we have the contents of the module. The `int3' file
            % does not depend on anything else.
            globals.lookup_bool_option(Globals, very_verbose, VeryVerbose),
            ( if set.is_empty(ReadModuleErrors) then
                Target = target_file(ModuleName, module_target_int3),
                maybe_make_target_message_to_stream(Globals, OldOutputStream,
                    Target, !IO),
                build_with_check_for_interrupt(VeryVerbose,
                    build_with_module_options(Globals, ModuleName,
                        ["--make-short-interface"],
                        make_int3_files(ErrorStream, ParseTreeModuleSrcs)
                    ),
                    cleanup_int3_files(Globals, SubModuleNames),
                    Succeeded, !Info, !IO)
            else
                Succeeded = no
            ),

            build_with_check_for_interrupt(VeryVerbose,
                ( pred(yes::out, MakeInfo::in, MakeInfo::out,
                        IO0::di, IO::uo) is det :-
                    list.foldl(do_write_module_dep_file(Globals),
                        ModuleAndImportsList, IO0, IO)
                ),
                cleanup_module_dep_files(Globals, SubModuleNames),
                _Succeeded, !Info, !IO),

            MadeTarget = target_file(ModuleName, module_target_int3),
            record_made_target(Globals, MadeTarget,
                process_module(task_make_int3), Succeeded, !Info, !IO),
            unredirect_output(Globals, ModuleName, ErrorStream, !Info, !IO)
        )
    ;
        MaybeErrorStream = no
    ).

:- pred make_info_add_module_and_imports_as_dep(module_and_imports::in,
    make_info::in, make_info::out) is det.

make_info_add_module_and_imports_as_dep(ModuleAndImports, !Info) :-
    module_and_imports_get_module_name(ModuleAndImports, ModuleName),
    ModuleDepInfo = module_dep_info_imports(ModuleAndImports),
    MaybeModuleDepInfo = some_module_dep_info(ModuleDepInfo),
    ModuleDeps0 = !.Info ^ module_dependencies,
    % XXX Could this be map.det_insert?
    map.set(ModuleName, MaybeModuleDepInfo, ModuleDeps0, ModuleDeps),
    !Info ^ module_dependencies := ModuleDeps.

:- pred make_int3_files(io.output_stream::in,
    list(parse_tree_module_src)::in, globals::in, list(string)::in, bool::out,
    make_info::in, make_info::out, io::di, io::uo) is det.

make_int3_files(ErrorStream, ParseTreeModuleSrcs, Globals, _, Succeeded,
        !Info, !IO) :-
    io.set_output_stream(ErrorStream, OutputStream, !IO),
    list.foldl(write_short_interface_file_int3(Globals),
        ParseTreeModuleSrcs, !IO),
    io.set_output_stream(OutputStream, _, !IO),
    io.get_exit_status(ExitStatus, !IO),
    Succeeded = ( if ExitStatus = 0 then yes else no ).

:- pred cleanup_int3_files(globals::in, list(module_name)::in,
    make_info::in, make_info::out, io::di, io::uo) is det.

cleanup_int3_files(Globals, ModuleNames, !Info, !IO) :-
    list.foldl2(cleanup_int3_file(Globals), ModuleNames, !Info, !IO).

:- pred cleanup_int3_file(globals::in, module_name::in,
    make_info::in, make_info::out, io::di, io::uo) is det.

cleanup_int3_file(Globals, ModuleName, !Info, !IO) :-
    make_remove_target_file_by_name(Globals, very_verbose,
        ModuleName, module_target_int3, !Info, !IO).

:- pred cleanup_module_dep_files(globals::in, list(module_name)::in,
    make_info::in, make_info::out, io::di, io::uo) is det.

cleanup_module_dep_files(Globals, ModuleNames, !Info, !IO) :-
    list.foldl2(cleanup_module_dep_file(Globals), ModuleNames, !Info, !IO).

:- pred cleanup_module_dep_file(globals::in, module_name::in,
    make_info::in, make_info::out, io::di, io::uo) is det.

cleanup_module_dep_file(Globals, ModuleName, !Info, !IO) :-
    make_remove_module_file(Globals, verbose_make, ModuleName,
        ext_other(make_module_dep_file_extension), !Info, !IO).

:- pred maybe_write_importing_module(module_name::in, maybe(module_name)::in,
    io::di, io::uo) is det.

maybe_write_importing_module(_, no, !IO).
maybe_write_importing_module(ModuleName, yes(ImportingModuleName), !IO) :-
    io.format("** Module `%s' is imported or included by module `%s'.\n",
        [s(sym_name_to_escaped_string(ModuleName)),
        s(sym_name_to_escaped_string(ImportingModuleName))], !IO).

%-----------------------------------------------------------------------------%
:- end_module make.module_dep_file.
%-----------------------------------------------------------------------------%
