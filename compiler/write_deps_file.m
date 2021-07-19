%---------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et
%---------------------------------------------------------------------------%
% Copyright (C) 2008-2011 The University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%---------------------------------------------------------------------------%
%
% File: write_deps_file.m.
%
%---------------------------------------------------------------------------%

:- module parse_tree.write_deps_file.
:- interface.

:- import_module libs.
:- import_module libs.file_util.
:- import_module libs.globals.
:- import_module mdbcomp.
:- import_module mdbcomp.sym_name.
:- import_module parse_tree.deps_map.
:- import_module parse_tree.file_names.
:- import_module parse_tree.module_deps_graph.
:- import_module parse_tree.module_imports.

:- import_module bool.
:- import_module io.
:- import_module list.
:- import_module maybe.
:- import_module set.

    % write_dependency_file(Globals, Module, AllDeps, MaybeTransOptDeps):
    %
    % Write out the per-module makefile dependencies (`.d') file for the
    % specified module. AllDeps is the set of all module names which the
    % generated code for this module might depend on, i.e. all that have been
    % used or imported, directly or indirectly, into this module, including
    % via .opt or .trans_opt files, and including parent modules of nested
    % modules. MaybeTransOptDeps is a list of module names which the
    % `.trans_opt' file may depend on. This is set to `no' if the
    % dependency list is not available.
    %
:- pred write_dependency_file(globals::in, module_and_imports::in,
    set(module_name)::in, maybe(list(module_name))::in, io::di, io::uo) is det.

    % generate_dependencies_write_d_files(Globals, Modules,
    %   IntDepsRel, ImplDepsRel, IndirectDepsRel, IndirectOptDepsRel,
    %   TransOptOrder, DepsMap, !IO):
    %
    % This predicate writes out the .d files for all the modules in the
    % Modules list.
    % IntDepsGraph gives the interface dependency graph.
    % ImplDepsGraph gives the implementation dependency graph.
    % IndirectDepsGraph gives the indirect dependency graph
    % (this includes dependencies on `*.int2' files).
    % IndirectOptDepsGraph gives the indirect optimization dependencies
    % (this includes dependencies via `.opt' and `.trans_opt' files).
    % These are all computed from the DepsMap.
    % TransOptOrder gives the ordering that is used to determine
    % which other modules the .trans_opt files may depend on.
    %
:- pred generate_dependencies_write_d_files(globals::in, list(deps)::in,
    deps_graph::in, deps_graph::in, deps_graph::in, deps_graph::in,
    list(module_name)::in, deps_map::in, io::di, io::uo) is det.

    % Write out the `.dv' file, using the information collected in the
    % deps_map data structure.
    %
:- pred generate_dependencies_write_dv_file(globals::in, file_name::in,
    module_name::in, deps_map::in, io::di, io::uo) is det.

    % Write out the `.dep' file, using the information collected in the
    % deps_map data structure.
    %
:- pred generate_dependencies_write_dep_file(globals::in, file_name::in,
    module_name::in, deps_map::in, io::di, io::uo) is det.

:- pred maybe_output_module_order(globals::in, module_name::in,
    list(set(module_name))::in, io::di, io::uo) is det.

%---------------------------------------------------------------------------%

    % For each dependency, search intermod_directories for a file with
    % the given extension, filtering out those for which the search fails.
    % If --use-opt-files is set, only look for `.opt' files,
    % not `.m' files.
    % XXX This won't find nested submodules.
    % XXX Use `mmc --make' if that matters.
    %
    % This predicate must operate on lists, not sets, of module names,
    % because it needs to preserve the chosen trans_opt deps ordering,
    % which is derived from the dependency graph between modules,
    % and not just the modules' names.
    %
:- pred get_opt_deps(globals::in, bool::in, list(string)::in, other_ext::in,
    list(module_name)::in, list(module_name)::out, io::di, io::uo) is det.

%---------------------------------------------------------------------------%
%---------------------------------------------------------------------------%

:- implementation.

:- import_module libs.options.
:- import_module libs.mmakefiles.
:- import_module make.                          % XXX undesirable dependency
:- import_module parse_tree.find_module.        % XXX undesirable dependency
:- import_module parse_tree.module_cmds.
:- import_module parse_tree.parse_error.
:- import_module parse_tree.prog_data.
:- import_module parse_tree.prog_data_foreign.
:- import_module parse_tree.prog_foreign.
:- import_module parse_tree.prog_item.
:- import_module parse_tree.prog_out.
:- import_module parse_tree.source_file_map.

:- import_module assoc_list.
:- import_module cord.
:- import_module digraph.
:- import_module dir.
:- import_module library.
:- import_module map.
:- import_module one_or_more.
:- import_module one_or_more_map.
:- import_module pair.
:- import_module require.
:- import_module sparse_bitset.
:- import_module string.
:- import_module term.

%---------------------------------------------------------------------------%

write_dependency_file(Globals, ModuleAndImports, AllDeps,
        MaybeTransOptDeps, !IO) :-
    globals.lookup_bool_option(Globals, verbose, Verbose),

    % To avoid problems with concurrent updates of `.d' files during
    % parallel makes, we first create the file with a temporary name,
    % and then rename it to the desired name when we have finished.
    module_and_imports_get_module_name(ModuleAndImports, ModuleName),
    module_name_to_file_name(Globals, $pred, do_create_dirs,
        ext_other(other_ext(".d")), ModuleName, DependencyFileName, !IO),
    io.make_temp_file(dir.dirname(DependencyFileName), "tmp_d",
        "", TmpDependencyFileNameRes, !IO),
    get_error_output_stream(Globals, ModuleName, ErrorStream, !IO),
    get_progress_output_stream(Globals, ModuleName, ProgressStream, !IO),
    (
        TmpDependencyFileNameRes = error(Error),
        Message = "Could not create temporary file: " ++ error_message(Error),
        report_error(ErrorStream, Message, !IO)
    ;
        TmpDependencyFileNameRes = ok(TmpDependencyFileName),
        (
            Verbose = no
        ;
            Verbose = yes,
            io.format(ProgressStream,
                "%% Writing auto-dependency file `%s'...",
                [s(DependencyFileName)], !IO),
            io.flush_output(ProgressStream, !IO)
        ),
        io.open_output(TmpDependencyFileName, Result, !IO),
        (
            Result = error(IOError),
            maybe_write_string(ProgressStream, Verbose, " failed.\n", !IO),
            maybe_flush_output(ProgressStream, Verbose, !IO),
            io.error_message(IOError, IOErrorMessage),
            string.format("error opening temporary file `%s' for output: %s",
                [s(TmpDependencyFileName), s(IOErrorMessage)], Message),
            report_error(ErrorStream, Message, !IO)
        ;
            Result = ok(DepStream),
            generate_d_file(Globals, ModuleAndImports,
                AllDeps, MaybeTransOptDeps, MmakeFile, !IO),
            write_mmakefile(DepStream, MmakeFile, !IO),
            io.close_output(DepStream, !IO),

            io.rename_file(TmpDependencyFileName, DependencyFileName,
                FirstRenameResult, !IO),
            (
                FirstRenameResult = error(_),
                % On some systems, we need to remove the existing file first,
                % if any. So try again that way.
                io.remove_file(DependencyFileName, RemoveResult, !IO),
                (
                    RemoveResult = error(Error4),
                    maybe_write_string(ProgressStream, Verbose,
                        " failed.\n", !IO),
                    maybe_flush_output(ProgressStream, Verbose, !IO),
                    io.error_message(Error4, ErrorMsg),
                    string.format("can't remove file `%s': %s",
                        [s(DependencyFileName), s(ErrorMsg)], Message),
                    report_error(ErrorStream, Message, !IO)
                ;
                    RemoveResult = ok,
                    io.rename_file(TmpDependencyFileName, DependencyFileName,
                        SecondRenameResult, !IO),
                    (
                        SecondRenameResult = error(Error5),
                        maybe_write_string(ProgressStream, Verbose,
                            " failed.\n", !IO),
                        maybe_flush_output(ProgressStream, Verbose, !IO),
                        io.error_message(Error5, ErrorMsg),
                        string.format("can't rename file `%s' as `%s': %s",
                            [s(TmpDependencyFileName), s(DependencyFileName),
                            s(ErrorMsg)], Message),
                        report_error(ErrorStream, Message, !IO)
                    ;
                        SecondRenameResult = ok,
                        maybe_write_string(ProgressStream, Verbose,
                            " done.\n", !IO)
                    )
                )
            ;
                FirstRenameResult = ok,
                maybe_write_string(ProgressStream, Verbose, " done.\n", !IO)
            )
        )
    ).

%---------------------------------------------------------------------------%
%---------------------------------------------------------------------------%

    % Generate the contents of the module's .d file.
    %
    % The mmake rules we construct treat C differently from Java and C#.
    % The reason is that we support using mmake when targeting C, but require
    % the use of --use-mmc-make when targeting Java and C#.
    %
    % Initially, when the only target language was C, the only build system
    % we had was mmake, so the mmake rules we generate here can do everything
    % that one wants to do when targeting C. When we added the ability to
    % target C# and Erlang, we implemented it for --use-mmc-make only,
    % *not* for mmake, so the entries we generate for C# and Erlang
    % mostly just forward the work to --use-mmc-make. Java is in between;
    % there are more mmake rules for it than for C# or Erlang, but far from
    % enough for full functionality. In an email to m-rev on 2020 may 25,
    % Julien said: "IIRC, most of the mmake rules for Java that are not
    % required by --use-mmc-make are long obsolete". Unfortunately,
    % apparently there is no documentation of *which* mmake rules for Java
    % are required by --use-mmc-make.
    %
:- pred generate_d_file(globals::in, module_and_imports::in,
    set(module_name)::in, maybe(list(module_name))::in,
    mmakefile::out, io::di, io::uo) is det.

generate_d_file(Globals, ModuleAndImports, AllDeps, MaybeTransOptDeps,
        !:MmakeFile, !IO) :-
    module_and_imports_d_file(ModuleAndImports,
        SourceFileName, SourceFileModuleName,
        Ancestors, PublicChildrenMap, MaybeTopModule,
        IntDepsMap, ImpDepsMap, IndirectDeps, FactDeps0,
        ForeignImportModules0, ForeignIncludeFilesCord, ContainsForeignCode,
        AugCompUnit),
    one_or_more_map.keys_as_set(IntDepsMap, IntDeps),
    one_or_more_map.keys_as_set(ImpDepsMap, ImpDeps),
    one_or_more_map.keys_as_set(PublicChildrenMap, PublicChildren),

    ModuleName = AugCompUnit ^ aci_module_name,
    ModuleNameString = sym_name_to_string(ModuleName),
    library.version(Version, FullArch),

    MmakeStartComment = mmake_start_comment("module dependencies",
        ModuleNameString, SourceFileName, Version, FullArch),

    module_name_to_make_var_name(ModuleName, ModuleMakeVarName),

    set.union(IntDeps, ImpDeps, LongDeps0),
    ShortDeps0 = IndirectDeps,
    set.delete(ModuleName, LongDeps0, LongDeps),
    set.difference(ShortDeps0, LongDeps, ShortDeps1),
    set.delete(ModuleName, ShortDeps1, ShortDeps),

    module_name_to_file_name(Globals, $pred, do_not_create_dirs,
        ext_other(other_ext(".trans_opt_date")),
        ModuleName, TransOptDateFileName, !IO),
    construct_trans_opt_deps_rule(Globals, MaybeTransOptDeps, LongDeps,
        TransOptDateFileName, MmakeRulesTransOpt, !IO),

    construct_fact_tables_entries(ModuleMakeVarName,
        SourceFileName, ObjFileName, FactDeps0,
        MmakeVarsFactTables, FactTableSourceGroups, MmakeRulesFactTables),

    ( if string.remove_suffix(SourceFileName, ".m", SourceFileBase) then
        ErrFileName = SourceFileBase ++ ".err"
    else
        unexpected($pred, "source file name doesn't end in `.m'")
    ),

    module_name_to_file_name(Globals, $pred, do_not_create_dirs,
        ext_other(other_ext(".optdate")), ModuleName, OptDateFileName, !IO),
    module_name_to_file_name(Globals, $pred, do_not_create_dirs,
        ext_other(other_ext(".c_date")), ModuleName, CDateFileName, !IO),
    module_name_to_file_name(Globals, $pred, do_not_create_dirs,
        ext_other(other_ext(".$O")), ModuleName, ObjFileName, !IO),
    module_name_to_file_name(Globals, $pred, do_not_create_dirs,
        ext_other(other_ext(".java_date")), ModuleName, JavaDateFileName, !IO),
    % XXX Why is the extension hardcoded to .pic_o here?  That looks wrong.
    % It should probably be .$(EXT_FOR_PIC_OBJECT) - juliensf.
    module_name_to_file_name(Globals, $pred, do_not_create_dirs,
        ext_other(other_ext(".pic_o")), ModuleName, PicObjFileName, !IO),
    module_name_to_file_name(Globals, $pred, do_not_create_dirs,
        ext_other(other_ext(".int0")), ModuleName, Int0FileName, !IO),

    construct_date_file_deps_rule(Globals, ModuleName, SourceFileName,
        Ancestors, LongDeps, ShortDeps, PublicChildren, Int0FileName,
        OptDateFileName, TransOptDateFileName, ForeignIncludeFilesCord,
        CDateFileName, JavaDateFileName, ErrFileName,
        FactTableSourceGroups, MmakeRuleDateFileDeps, !IO),

    construct_build_nested_children_first_rule(Globals,
        ModuleName, MaybeTopModule, MmakeRulesNestedDeps, !IO),

    construct_intermod_rules(Globals, ModuleName, LongDeps, AllDeps,
        ErrFileName, TransOptDateFileName, CDateFileName, JavaDateFileName,
        ObjFileName, MmakeRulesIntermod, !IO),

    module_name_to_file_name(Globals, $pred, do_not_create_dirs,
        ext_other(other_ext(".c")), ModuleName, CFileName, !IO),
    construct_c_header_rules(Globals, ModuleName, AllDeps,
        CFileName, ObjFileName, PicObjFileName, MmakeRulesCHeaders, !IO),

    construct_module_dep_fragment(Globals, ModuleName, CFileName,
        MmakeFragmentModuleDep, !IO),

    module_name_to_file_name(Globals, $pred, do_not_create_dirs,
        ext_other(other_ext(".date")), ModuleName, DateFileName, !IO),
    module_name_to_file_name(Globals, $pred, do_not_create_dirs,
        ext_other(other_ext(".date0")), ModuleName, Date0FileName, !IO),
    construct_self_and_parent_date_date0_rules(Globals, SourceFileName,
        Date0FileName, DateFileName, Ancestors, LongDeps, ShortDeps,
        MmakeRulesParentDates, !IO),

    construct_foreign_import_rules(Globals, AugCompUnit, SourceFileModuleName,
        ContainsForeignCode, ForeignImportModules0,
        ObjFileName, PicObjFileName, MmakeRulesForeignImports, !IO),

    module_name_to_file_name(Globals, $pred, do_not_create_dirs,
        ext_other(other_ext(".date3")), ModuleName, Date3FileName, !IO),
    construct_install_shadow_rules(Globals, ModuleName,
        Int0FileName, Date0FileName, DateFileName, Date3FileName,
        OptDateFileName, TransOptDateFileName,
        MmakeRulesInstallShadows, !IO),

    construct_subdir_short_rules(Globals, ModuleName,
        MmakeRulesSubDirShorthand, !IO),

    have_source_file_map(HaveMap, !IO),
    construct_any_needed_pattern_rules(HaveMap,
        ModuleName, SourceFileModuleName, SourceFileName,
        Date0FileName, DateFileName, Date3FileName,
        OptDateFileName, TransOptDateFileName, CDateFileName, JavaDateFileName,
        MmakeRulesPatterns),

    start_mmakefile(!:MmakeFile),
    add_mmake_entry(MmakeStartComment, !MmakeFile),
    add_mmake_entries(MmakeRulesTransOpt, !MmakeFile),
    add_mmake_entries(MmakeVarsFactTables, !MmakeFile),
    add_mmake_entry(MmakeRuleDateFileDeps, !MmakeFile),
    add_mmake_entries(MmakeRulesFactTables, !MmakeFile),
    add_mmake_entries(MmakeRulesNestedDeps, !MmakeFile),
    add_mmake_entries(MmakeRulesIntermod, !MmakeFile),
    add_mmake_entries(MmakeRulesCHeaders, !MmakeFile),
    add_mmake_fragment(MmakeFragmentModuleDep, !MmakeFile),
    add_mmake_entries(MmakeRulesParentDates, !MmakeFile),
    add_mmake_entries(MmakeRulesForeignImports, !MmakeFile),
    add_mmake_entries(MmakeRulesInstallShadows, !MmakeFile),
    add_mmake_entries(MmakeRulesSubDirShorthand, !MmakeFile),
    add_mmake_entries(MmakeRulesPatterns, !MmakeFile).

%---------------------%

:- pred construct_trans_opt_deps_rule(globals::in,
    maybe(list(module_name))::in, set(module_name)::in, string::in,
    list(mmake_entry)::out, io::di, io::uo) is det.

construct_trans_opt_deps_rule(Globals, MaybeTransOptDeps, LongDeps,
        TransOptDateFileName, MmakeRulesTransOpt, !IO) :-
    (
        MaybeTransOptDeps = yes(TransOptDeps0),
        set.intersect(set.list_to_set(TransOptDeps0), LongDeps,
            TransOptDateDeps),
        % Note that maybe_read_dependency_file searches for
        % this exact pattern.
        make_module_file_names_with_suffix(Globals,
            ext_other(other_ext(".trans_opt")),
            set.to_sorted_list(TransOptDateDeps), TransOptDateDepsFileNames,
            !IO),
        MmakeRuleTransOpt = mmake_simple_rule("trans_opt_deps",
            mmake_rule_is_not_phony,
            TransOptDateFileName,
            TransOptDateDepsFileNames,
            []),
        MmakeRulesTransOpt = [MmakeRuleTransOpt]
    ;
        MaybeTransOptDeps = no,
        MmakeRulesTransOpt = []
    ).

%---------------------%

:- pred construct_fact_tables_entries(string::in, string::in, string::in,
    list(string)::in,
    list(mmake_entry)::out, list(mmake_file_name_group)::out,
    list(mmake_entry)::out) is det.

construct_fact_tables_entries(ModuleMakeVarName, SourceFileName, ObjFileName,
        FactDeps0, MmakeVarsFactTables, FactTableSourceGroups,
        MmakeRulesFactTables) :-
    list.sort_and_remove_dups(FactDeps0, FactDeps),
    (
        FactDeps = [_ | _],
        MmakeVarFactTables = mmake_var_defn_list(
            ModuleMakeVarName ++ ".fact_tables",
            FactDeps),
        MmakeVarFactTablesOs = mmake_var_defn(
            ModuleMakeVarName ++ ".fact_tables.os",
            "$(" ++ ModuleMakeVarName ++ ".fact_tables:%=$(os_subdir)%.$O)"),
        MmakeVarFactTablesAllOs = mmake_var_defn(
            ModuleMakeVarName ++ ".fact_tables.all_os",
            "$(" ++ ModuleMakeVarName ++ ".fact_tables:%=$(os_subdir)%.$O)"),
        MmakeVarFactTablesCs = mmake_var_defn(
            ModuleMakeVarName ++ ".fact_tables.cs",
            "$(" ++ ModuleMakeVarName ++ ".fact_tables:%=$(cs_subdir)%.c)"),
        MmakeVarFactTablesAllCs = mmake_var_defn(
            ModuleMakeVarName ++ ".fact_tables.all_cs",
            "$(" ++ ModuleMakeVarName ++ ".fact_tables:%=$(cs_subdir)%.c)"),
        MmakeVarsFactTables =
            [MmakeVarFactTables,
            MmakeVarFactTablesOs, MmakeVarFactTablesAllOs,
            MmakeVarFactTablesCs, MmakeVarFactTablesAllCs],

        FactTableSourceGroup = mmake_file_name_group("fact tables",
            one_or_more("$(" ++ ModuleMakeVarName ++ ".fact_tables)", [])),
        FactTableSourceGroups = [FactTableSourceGroup],

        % XXX These rules seem wrong to me. -zs
        MmakeRuleFactOs = mmake_simple_rule("fact_table_os",
            mmake_rule_is_not_phony,
            "$(" ++ ModuleMakeVarName ++ ".fact_tables.os)",
            ["$(" ++ ModuleMakeVarName ++  ".fact_tables)", SourceFileName],
            []),
        MmakeRuleFactCs = mmake_simple_rule("fact_table_cs",
            mmake_rule_is_not_phony,
            "$(" ++ ModuleMakeVarName ++ ".fact_tables.cs)",
            [ObjFileName],
            []),
        MmakeRulesFactTables = [MmakeRuleFactOs, MmakeRuleFactCs]
    ;
        FactDeps = [],
        MmakeVarsFactTables = [],
        FactTableSourceGroups = [],
        MmakeRulesFactTables = []
    ).

%---------------------%

:- pred construct_date_file_deps_rule(globals::in,
    module_name::in, string::in,
    set(module_name)::in, set(module_name)::in, set(module_name)::in,
    set(module_name)::in, string::in, string::in, string::in,
    cord(foreign_include_file_info)::in, string::in, string::in, string::in,
    list(mmake_file_name_group)::in,
    mmake_entry::out, io::di, io::uo) is det.

construct_date_file_deps_rule(Globals, ModuleName, SourceFileName,
        Ancestors, LongDeps, ShortDeps, PublicChildren, Int0FileName,
        OptDateFileName, TransOptDateFileName, ForeignIncludeFilesCord,
        CDateFileName, JavaDateFileName, ErrFileName,
        FactTableSourceGroups, MmakeRuleDateFileDeps, !IO) :-
    % For the reason for why there is no mention of a date file for C# here,
    % see the comment at the top of generate_d_file.
    TargetGroup = mmake_file_name_group("dates_and_err",
        one_or_more(OptDateFileName,
            [TransOptDateFileName, ErrFileName,
            CDateFileName, JavaDateFileName])),
    TargetGroups = one_or_more(TargetGroup, []),

    SourceFileNameGroup = [make_singleton_file_name_group(SourceFileName)],
    % If the module contains nested submodules, then the `.int0' file
    % must first be built.
    ( if set.is_empty(PublicChildren) then
        Int0FileNameGroups = []
    else
        Int0FileNameGroups = [make_singleton_file_name_group(Int0FileName)]
    ),
    make_module_file_name_group_with_suffix(Globals,
        "ancestors", ext_other(other_ext(".int0")),
        Ancestors, AncestorSourceGroups, !IO),
    make_module_file_name_group_with_suffix(Globals,
        "long deps", ext_other(other_ext(".int")),
        LongDeps, LongDepsSourceGroups, !IO),
    make_module_file_name_group_with_suffix(Globals,
        "short deps", ext_other(other_ext(".int2")),
        ShortDeps, ShortDepsSourceGroups, !IO),
    make_module_file_name_group_with_suffix(Globals,
        "type_repn self dep", ext_other(other_ext(".int")),
        set.make_singleton_set(ModuleName), TypeRepnSelfDepGroups, !IO),
    ForeignIncludeFiles = cord.list(ForeignIncludeFilesCord),
    % This is conservative: a target file for foreign language A
    % does not truly depend on a file included for foreign language B.
    ForeignImportFileNames =
        list.map(foreign_include_file_path_name(SourceFileName),
            ForeignIncludeFiles),
    ForeignImportFileNameGroup =
        make_file_name_group("foreign imports", ForeignImportFileNames),
    SourceGroups = SourceFileNameGroup ++
        Int0FileNameGroups ++ AncestorSourceGroups ++
        LongDepsSourceGroups ++ ShortDepsSourceGroups ++
        TypeRepnSelfDepGroups ++
        ForeignImportFileNameGroup ++ FactTableSourceGroups,
    MmakeRuleDateFileDeps = mmake_general_rule("date_file_deps",
        mmake_rule_is_not_phony,
        TargetGroups,
        SourceGroups,
        []).

%---------------------%

    % If a module contains nested submodules, then we need to build
    % the nested children before attempting to build the parent module.
    % Build rules that enforce this.
    %
:- pred construct_build_nested_children_first_rule(globals::in,
    module_name::in, maybe_top_module::in, list(mmake_entry)::out,
    io::di, io::uo) is det.

construct_build_nested_children_first_rule(Globals, ModuleName, MaybeTopModule,
        MmakeRulesNestedDeps, !IO) :-
    NestedModuleNames = get_nested_children_list_of_top_module(MaybeTopModule),
    (
        NestedModuleNames = [],
        MmakeRulesNestedDeps = []
    ;
        NestedModuleNames = [_ | _],
        NestedOtherExts = [
            other_ext(".optdate"),
            other_ext(".trans_opt_date"),
            other_ext(".c_date"),
            other_ext(".dir/*.$O"),
            other_ext(".java_date")],
        list.map_foldl(
            gather_nested_deps(Globals, ModuleName, NestedModuleNames),
            NestedOtherExts, MmakeRulesNestedDeps, !IO)
    ).

%---------------------%

:- pred construct_intermod_rules(globals::in, module_name::in,
    set(module_name)::in, set(module_name)::in,
    string::in, string::in, string::in, string::in, string::in,
    list(mmake_entry)::out, io::di, io::uo) is det.

construct_intermod_rules(Globals, ModuleName, LongDeps, AllDeps,
        ErrFileName, TransOptDateFileName, CDateFileName, JavaDateFileName,
        ObjFileName, MmakeRulesIntermod, !IO) :-
    % XXX Note that currently, due to a design problem, handle_option.m
    % *always* sets use_opt_files to no.
    globals.lookup_bool_option(Globals, use_opt_files, UseOptFiles),
    globals.lookup_bool_option(Globals, intermodule_optimization,
        Intermod),
    globals.lookup_accumulating_option(Globals, intermod_directories,
        IntermodDirs),

    % If intermodule_optimization is enabled, then all the .mh files
    % must exist, because it is possible that the .c file imports them
    % directly or indirectly.
    (
        Intermod = yes,
        make_module_file_names_with_suffix(Globals,
            ext_other(other_ext(".mh")),
            set.to_sorted_list(AllDeps), AllDepsFileNames, !IO),
        MmakeRuleMhDeps = mmake_simple_rule("machine_dependent_header_deps",
            mmake_rule_is_not_phony,
            ObjFileName,
            AllDepsFileNames,
            []),
        MmakeRulesMhDeps = [MmakeRuleMhDeps]
    ;
        Intermod = no,
        MmakeRulesMhDeps = []
    ),
    ( if
        ( Intermod = yes
        ; UseOptFiles = yes
        )
    then
        Targets = one_or_more(TransOptDateFileName,
            [ErrFileName, CDateFileName, JavaDateFileName]),

        % The target (e.g. C) file only depends on the .opt files from the
        % current directory, so that inter-module optimization works when
        % the .opt files for the library are unavailable. This is only
        % necessary because make doesn't allow conditional dependencies.
        % The dependency on the current module's .opt file is to make sure
        % the module gets type-checked without having the definitions
        % of abstract types from other modules.
        %
        % XXX The code here doesn't correctly handle dependencies
        % on `.int' and `.int2' files needed by the `.opt' files.
        globals.lookup_bool_option(Globals, transitive_optimization, TransOpt),
        globals.lookup_bool_option(Globals, use_trans_opt_files,
            UseTransOpt),

        bool.not(UseTransOpt, BuildOptFiles),
        ( if
            ( TransOpt = yes
            ; UseTransOpt = yes
            )
        then
            get_both_opt_deps(Globals, BuildOptFiles, IntermodDirs,
                [ModuleName | set.to_sorted_list(LongDeps)],
                OptDeps, TransOptDeps1, !IO),
            MaybeTransOptDeps1 = yes(TransOptDeps1)
        else
            get_opt_deps(Globals, BuildOptFiles, IntermodDirs,
                other_ext(".opt"),
                [ModuleName | set.to_sorted_list(LongDeps)],
                OptDeps, !IO),
            MaybeTransOptDeps1 = no
        ),

        OptInt0Deps = set.union_list(list.map(get_ancestors_set, OptDeps)),
        make_module_file_names_with_suffix(Globals,
            ext_other(other_ext(".opt")),
            OptDeps, OptDepsFileNames, !IO),
        make_module_file_names_with_suffix(Globals,
            ext_other(other_ext(".int0")),
            set.to_sorted_list(OptInt0Deps), OptInt0DepsFileNames, !IO),
        MmakeRuleDateOptInt0Deps = mmake_flat_rule("dates_on_opts_and_int0s",
            mmake_rule_is_not_phony,
            Targets,
            OptDepsFileNames ++ OptInt0DepsFileNames,
            []),

        (
            MaybeTransOptDeps1 = yes(TransOptDeps2),
            ErrDateTargets = one_or_more(ErrFileName,
                [CDateFileName, JavaDateFileName]),
            make_module_file_names_with_suffix(Globals,
                ext_other(other_ext(".trans_opt")),
                TransOptDeps2, TransOptDepsOptFileNames, !IO),
            MmakeRuleTransOptOpts = mmake_flat_rule("dates_on_trans_opts",
                mmake_rule_is_not_phony,
                ErrDateTargets,
                TransOptDepsOptFileNames,
                []),
            MmakeRulesIntermod = MmakeRulesMhDeps ++
                [MmakeRuleDateOptInt0Deps, MmakeRuleTransOptOpts]
        ;
            MaybeTransOptDeps1 = no,
            MmakeRulesIntermod = MmakeRulesMhDeps ++ [MmakeRuleDateOptInt0Deps]
        )
    else
        MmakeRulesIntermod = MmakeRulesMhDeps
    ).

%---------------------%

:- pred construct_c_header_rules(globals::in, module_name::in,
    set(module_name)::in, string::in, string::in, string::in,
    list(mmake_entry)::out, io::di, io::uo) is det.

construct_c_header_rules(Globals, ModuleName, AllDeps,
        CFileName, ObjFileName, PicObjFileName, MmakeRulesCHeaders, !IO) :-
    globals.lookup_bool_option(Globals, highlevel_code, HighLevelCode),
    globals.get_target(Globals, CompilationTarget),
    ( if
        HighLevelCode = yes,
        CompilationTarget = target_c
    then
        % For --high-level-code with --target c, we need to make sure that
        % we generate the header files for imported modules before compiling
        % the C files, since the generated C files #include those header files.
        Targets = one_or_more(PicObjFileName, [ObjFileName]),
        make_module_file_names_with_suffix(Globals,
            ext_other(other_ext(".mih")),
            set.to_sorted_list(AllDeps), AllDepsFileNames, !IO),
        MmakeRuleObjOnMihs = mmake_flat_rule("objs_on_mihs",
            mmake_rule_is_not_phony,
            Targets,
            AllDepsFileNames,
            []),
        MmakeRulesObjOnMihs = [MmakeRuleObjOnMihs]
    else
        MmakeRulesObjOnMihs = []
    ),

    % We need to tell make how to make the header files. The header files
    % are actually built by the same command that creates the .c or .s file,
    % so we just make them depend on the .c or .s files. This is needed
    % for the --high-level-code rule above, and for the rules introduced for
    % `:- pragma foreign_import_module' declarations. In some grades the header
    % file won't actually be built (e.g. LLDS grades for modules not containing
    % `:- pragma export' declarations), but this rule won't do any harm.
    module_name_to_file_name(Globals, $pred, do_not_create_dirs,
        ext_other(other_ext(".mh")), ModuleName, MhHeaderFileName, !IO),
    module_name_to_file_name(Globals, $pred, do_not_create_dirs,
        ext_other(other_ext(".mih")), ModuleName, MihHeaderFileName, !IO),
    MmakeRuleMhMihOnC = mmake_flat_rule("mh_and_mih_on_c",
        mmake_rule_is_not_phony,
        one_or_more(MhHeaderFileName, [MihHeaderFileName]),
        [CFileName],
        []),
    MmakeRulesCHeaders = MmakeRulesObjOnMihs ++ [MmakeRuleMhMihOnC].

%---------------------%

    % The `.module_dep' file is made as a side effect of
    % creating the `.c' or `.java'.
    % XXX What about C#?
    % (See the main comment on generate_d_file above.
    %
:- pred construct_module_dep_fragment(globals::in, module_name::in,
    string::in, mmake_fragment::out, io::di, io::uo) is det.

construct_module_dep_fragment(Globals, ModuleName, CFileName,
        MmakeFragmentModuleDep, !IO) :-
    module_name_to_file_name(Globals, $pred, do_not_create_dirs,
        ext_other(other_ext(".java")), ModuleName, JavaFileName, !IO),
    module_name_to_file_name(Globals, $pred, do_not_create_dirs,
        ext_other(make_module_dep_file_extension),
        ModuleName, ModuleDepFileName, !IO),
    MmakeFragmentModuleDep = mmf_conditional_entry(
        mmake_cond_grade_has_component("java"),
        mmake_simple_rule("module_dep_on_java",
            mmake_rule_is_not_phony,
            ModuleDepFileName,
            [JavaFileName],
            []),
        mmake_simple_rule("module_dep_on_c",
            mmake_rule_is_not_phony,
            ModuleDepFileName,
            [CFileName],
            [])
    ).

%---------------------%

    % The .date and .date0 files depend on the .int0 files for the parent
    % modules, and the .int3 files for the directly and indirectly imported
    % modules.
    %
    % For nested submodules, the `.date' files for the parent modules
    % also depend on the same things as the `.date' files for this module,
    % since all the `.date' files will get produced by a single mmc command.
    % Similarly for `.date0' files, except these don't depend on the `.int0'
    % files, because when doing the `--make-private-interface' for nested
    % modules, mmc will process the modules in outermost to innermost order
    % so as to produce each `.int0' file before it is needed.
    %
:- pred construct_self_and_parent_date_date0_rules(globals::in,
    string::in, string::in, string::in,
    set(module_name)::in, set(module_name)::in, set(module_name)::in,
    list(mmake_entry)::out, io::di, io::uo) is det.

construct_self_and_parent_date_date0_rules(Globals, SourceFileName,
        Date0FileName, DateFileName, Ancestors, LongDeps, ShortDeps,
        MmakeRulesParentDates, !IO) :-
    make_module_file_names_with_suffix(Globals,
        ext_other(other_ext(".date")),
        set.to_sorted_list(Ancestors), AncestorDateFileNames, !IO),
    make_module_file_names_with_suffix(Globals,
        ext_other(other_ext(".int0")),
        set.to_sorted_list(Ancestors), AncestorInt0FileNames, !IO),
    make_module_file_names_with_suffix(Globals,
        ext_other(other_ext(".int3")),
        set.to_sorted_list(LongDeps), LongDepInt3FileNames, !IO),
    make_module_file_names_with_suffix(Globals,
        ext_other(other_ext(".int3")),
        set.to_sorted_list(ShortDeps), ShortDepInt3FileNames, !IO),

    MmakeRuleParentDates = mmake_general_rule("self_and_parent_date_deps",
        mmake_rule_is_not_phony,
        one_or_more(
            mmake_file_name_group("",
                one_or_more(DateFileName,
                    [Date0FileName | AncestorDateFileNames])),
            []),
        [make_singleton_file_name_group(SourceFileName)] ++
            make_file_name_group("ancestor int0", AncestorInt0FileNames) ++
            make_file_name_group("long dep int3s", LongDepInt3FileNames) ++
            make_file_name_group("short dep int3s", ShortDepInt3FileNames),
        []),
    make_module_file_names_with_suffix(Globals,
        ext_other(other_ext(".date0")),
        set.to_sorted_list(Ancestors), AncestorDate0FileNames, !IO),
    MmakeRuleParentDate0s = mmake_general_rule("self_and_parent_date0_deps",
        mmake_rule_is_not_phony,
        one_or_more(
            mmake_file_name_group("date0s",
                one_or_more(Date0FileName, AncestorDate0FileNames)),
            []),
        [make_singleton_file_name_group(SourceFileName)] ++
            make_file_name_group("long dep int3s", LongDepInt3FileNames) ++
            make_file_name_group("short dep int3s", ShortDepInt3FileNames),
        []),
    MmakeRulesParentDates = [MmakeRuleParentDates, MmakeRuleParentDate0s].

%---------------------%

:- pred construct_foreign_import_rules(globals::in, aug_compilation_unit::in,
    module_name::in, contains_foreign_code::in, c_j_cs_fims::in,
    string::in, string::in, list(mmake_entry)::out, io::di, io::uo) is det.

construct_foreign_import_rules(Globals, AugCompUnit, SourceFileModuleName,
        ContainsForeignCode, ForeignImportModules0,
        ObjFileName, PicObjFileName, MmakeRulesForeignImports, !IO) :-
    ModuleName = AugCompUnit ^ aci_module_name,
    (
        ContainsForeignCode = foreign_code_langs_known(_ForeignCodeLangs),
        % XXX This looks wrong to me (zs) in cases when _ForeignCodeLangs
        % is not the empty set. It is possible that in all such cases,
        % ForeignImportModules0 already contains the needed
        % foreign_import_module declarations, but it would be nice to see
        % a reasoned correctness argument about that.
        FIMSpecs = get_all_fim_specs(ForeignImportModules0)
    ;
        ContainsForeignCode = foreign_code_langs_unknown,
        % If we are generating the `.dep' file, ForeignImportModules0
        % will contain a conservative approximation to the set of foreign
        % imports needed which will include imports required by imported
        % modules.
        % XXX ITEM_LIST What is the correctness argument that supports
        % the above assertion?
        % XXX ITEM_LIST And even if it is true, how does that lead to
        % us adding the foreign_import_module declarations from the
        % interface and optimization files to ForeignImportModules
        % ONLY if ForeignImportModules0 contains nothing?
        % (Actually, we are replacing ForeignImportModules0 with them,
        % but when ForeignImportModules0 contains nothing, that is equivalent
        % to addition.)
        ( if
            ForeignImportModules0 = c_j_cs_fims(C0, Java0, CSharp0),
            set.is_empty(C0),
            set.is_empty(Java0),
            set.is_empty(CSharp0)
        then
            AugCompUnit = aug_compilation_unit(_, _, _, _ParseTreeModuleSrc,
                AncestorIntSpecs, DirectIntSpecs, IndirectIntSpecs,
                PlainOpts, _TransOpts, IntForOptSpecs, _TypeRepnSpecs),
            some [!FIMSpecs] (
                set.init(!:FIMSpecs),
                map.foldl_values(gather_fim_specs_in_ancestor_int_spec,
                    AncestorIntSpecs, !FIMSpecs),
                map.foldl_values(gather_fim_specs_in_direct_int_spec,
                    DirectIntSpecs, !FIMSpecs),
                map.foldl_values(gather_fim_specs_in_indirect_int_spec,
                    IndirectIntSpecs, !FIMSpecs),
                map.foldl_values(gather_fim_specs_in_parse_tree_plain_opt,
                    PlainOpts, !FIMSpecs),
                % .trans_opt files cannot contain FIMs.
                map.foldl_values(gather_fim_specs_in_int_for_opt_spec,
                    IntForOptSpecs, !FIMSpecs),
                % Any FIMs in type_repn_specs are ignored.

                % We restrict the set of FIMs to those that are valid
                % for the current backend. This preserves old behavior,
                % and makes sense in that the code below generates mmake rules
                % only for the current backend, but it would be nice if we
                % could generate dependency rules for *all* the backends.
                globals.get_backend_foreign_languages(Globals, BackendLangs),
                IsBackendFIM =
                    ( pred(FIMSpec::in) is semidet :-
                        list.member(FIMSpec ^ fimspec_lang, BackendLangs)
                    ),
                set.filter(IsBackendFIM, !.FIMSpecs, FIMSpecs)
            )
        else
            FIMSpecs = get_all_fim_specs(ForeignImportModules0)
        )
    ),

    % Handle dependencies introduced by
    % `:- pragma foreign_import_module' declarations.
    set.filter_map(
        ( pred(ForeignImportMod::in, ImportModuleName::out) is semidet :-
            ImportModuleName = fim_spec_module_name_from_module(
                ForeignImportMod, SourceFileModuleName),

            % XXX We can't include mercury.dll as mmake can't find it,
            % but we know that it exists.
            ImportModuleName \= unqualified("mercury")
        ), FIMSpecs, ForeignImportedModuleNamesSet),
    ForeignImportedModuleNames =
        set.to_sorted_list(ForeignImportedModuleNamesSet),
    (
        ForeignImportedModuleNames = [],
        MmakeRulesForeignImports = []
    ;
        ForeignImportedModuleNames = [_ | _],
        globals.get_target(Globals, Target),
        (
            Target = target_c,
            % NOTE: for C the possible targets might be a .o file _or_ a
            % .pic_o file. We need to include dependencies for the latter
            % otherwise invoking mmake with a <module>.pic_o target will break.
            ForeignImportTargets = [ObjFileName, PicObjFileName],
            ForeignImportOtherExt = other_ext(".mh")
        ;
            Target = target_java,
            module_name_to_file_name(Globals, $pred, do_not_create_dirs,
                ext_other(other_ext(".class")),
                ModuleName, ClassFileName, !IO),
            ForeignImportTargets = [ClassFileName],
            ForeignImportOtherExt = other_ext(".java")
        ;
            Target = target_csharp,
            % XXX don't know enough about C# yet
            ForeignImportTargets = [],
            ForeignImportOtherExt = other_ext(".cs")
        ),
        % XXX Instead of generating a separate rule for each target in
        % ForeignImportTargets, generate one rule with all those targets
        % before the colon.
        list.map_foldl(
            gather_foreign_import_deps(Globals, ForeignImportOtherExt,
                ForeignImportedModuleNames),
            ForeignImportTargets, MmakeRulesForeignImports, !IO)
    ).

%---------------------%

    % We add some extra dependencies to the generated `.d' files, so that
    % local `.int', `.opt', etc. files shadow the installed versions properly
    % (e.g. for when you are trying to build a new version of an installed
    % library). This saves the user from having to add these explicitly
    % if they have multiple libraries installed in the same installation
    % hierarchy which aren't independent (e.g. one uses another). These extra
    % dependencies are necessary due to the way the combination of search paths
    % and pattern rules works in Make.
    %
:- pred construct_install_shadow_rules(globals::in, module_name::in,
    string::in, string::in, string::in, string::in, string::in, string::in,
    list(mmake_entry)::out, io::di, io::uo) is det.

construct_install_shadow_rules(Globals, ModuleName,
        Int0FileName, Date0FileName, DateFileName, Date3FileName,
        OptDateFileName, TransOptDateFileName,
        MmakeRulesInstallShadows, !IO) :-
    module_name_to_file_name(Globals, $pred, do_not_create_dirs,
        ext_other(other_ext(".int")), ModuleName, IntFileName, !IO),
    module_name_to_file_name(Globals, $pred, do_not_create_dirs,
        ext_other(other_ext(".int2")), ModuleName, Int2FileName, !IO),
    module_name_to_file_name(Globals, $pred, do_not_create_dirs,
        ext_other(other_ext(".int3")), ModuleName, Int3FileName, !IO),
    module_name_to_file_name(Globals, $pred, do_not_create_dirs,
        ext_other(other_ext(".opt")), ModuleName, OptFileName, !IO),
    module_name_to_file_name(Globals, $pred, do_not_create_dirs,
        ext_other(other_ext(".trans_opt")), ModuleName, TransOptFileName, !IO),

    MmakeRulesInstallShadows = [
        mmake_simple_rule("int0_on_date0",
            mmake_rule_is_not_phony,
            Int0FileName, [Date0FileName], [silent_noop_action]),
        mmake_simple_rule("int_on_date",
            mmake_rule_is_not_phony,
            IntFileName, [DateFileName], [silent_noop_action]),
        mmake_simple_rule("int2_on_date",
            mmake_rule_is_not_phony,
            Int2FileName, [DateFileName], [silent_noop_action]),
        mmake_simple_rule("int3_on_date3",
            mmake_rule_is_not_phony,
            Int3FileName, [Date3FileName], [silent_noop_action]),
        mmake_simple_rule("opt_on_opt_date",
            mmake_rule_is_not_phony,
            OptFileName, [OptDateFileName], [silent_noop_action]),
        mmake_simple_rule("trans_opt_on_trans_opt_date",
            mmake_rule_is_not_phony,
            TransOptFileName, [TransOptDateFileName], [silent_noop_action])
    ].

%---------------------%

:- pred construct_subdir_short_rules(globals::in, module_name::in,
    list(mmake_entry)::out, io::di, io::uo) is det.

construct_subdir_short_rules(Globals, ModuleName,
        MmakeRulesSubDirShorthand, !IO) :-
    globals.lookup_bool_option(Globals, use_subdirs, UseSubdirs),
    (
        UseSubdirs = yes,
        SubDirShorthandOtherExts =
            [other_ext(".c"), other_ext(".$O"), other_ext(".pic_o"),
            other_ext(".java"), other_ext(".class"), other_ext(".dll")],
        list.map_foldl(
            construct_subdirs_shorthand_rule(Globals, ModuleName),
            SubDirShorthandOtherExts, MmakeRulesSubDirShorthand, !IO)
    ;
        UseSubdirs = no,
        MmakeRulesSubDirShorthand = []
    ).

%---------------------%

:- pred construct_any_needed_pattern_rules(bool::in,
    module_name::in, module_name::in, string::in,
    string::in, string::in, string::in,
    string::in, string::in, string::in, string::in,
    list(mmake_entry)::out) is det.

construct_any_needed_pattern_rules(HaveMap,
        ModuleName ,SourceFileModuleName, SourceFileName,
        Date0FileName, DateFileName, Date3FileName,
        OptDateFileName, TransOptDateFileName, CDateFileName, JavaDateFileName,
        MmakeRulesPatterns) :-
    % If we can pass the module name rather than the file name, then do so.
    % `--smart-recompilation' doesn't work if the file name is passed
    % and the module name doesn't match the file name.
    (
        HaveMap = yes,
        module_name_to_file_name_stem(SourceFileModuleName, ModuleArg)
    ;
        HaveMap = no,
        ModuleArg = SourceFileName
    ),
    ( if SourceFileName = default_source_file_name(ModuleName) then
        MmakeRulesPatterns = []
    else
        % The pattern rules in Mmake.rules won't work, since the source file
        % name doesn't match the expected source file name for this module
        % name. This can occur due to just the use of different source file
        % names, or it can be due to the use of nested modules. So we need
        % to output hard-coded rules in this case.
        %
        % The rules output below won't work in the case of nested modules
        % with parallel makes, because it will end up invoking the same command
        % twice (since it produces two output files) at the same time.
        %
        % Any changes here will require corresponding changes to
        % scripts/Mmake.rules. See that file for documentation on these rules.

        MmakeRulesPatterns = [
            mmake_simple_rule("date0_on_src",
                mmake_rule_is_not_phony,
                Date0FileName, [SourceFileName],
                ["$(MCPI) $(ALL_GRADEFLAGS) $(ALL_MCPIFLAGS) " ++ ModuleArg]),
            mmake_simple_rule("date_on_src",
                mmake_rule_is_not_phony,
                DateFileName, [SourceFileName],
                ["$(MCI) $(ALL_GRADEFLAGS) $(ALL_MCIFLAGS) " ++ ModuleArg]),
            mmake_simple_rule("date3_on_src",
                mmake_rule_is_not_phony,
                Date3FileName, [SourceFileName],
                ["$(MCSI) $(ALL_GRADEFLAGS) $(ALL_MCSIFLAGS) " ++ ModuleArg]),
            mmake_simple_rule("opt_date_on_src",
                mmake_rule_is_not_phony,
                OptDateFileName, [SourceFileName],
                ["$(MCOI) $(ALL_GRADEFLAGS) $(ALL_MCOIFLAGS) " ++ ModuleArg]),
            mmake_simple_rule("trans_opt_date_on_src",
                mmake_rule_is_not_phony,
                TransOptDateFileName, [SourceFileName],
                ["$(MCTOI) $(ALL_GRADEFLAGS) $(ALL_MCTOIFLAGS) " ++
                    ModuleArg]),
            mmake_simple_rule("c_date_on_src",
                mmake_rule_is_not_phony,
                CDateFileName, [SourceFileName],
                ["$(MCG) $(ALL_GRADEFLAGS) $(ALL_MCGFLAGS) " ++ ModuleArg ++
                    " $(ERR_REDIRECT)"]),
            mmake_simple_rule("java_date_on_src",
                mmake_rule_is_not_phony,
                JavaDateFileName, [SourceFileName],
                ["$(MCG) $(ALL_GRADEFLAGS) $(ALL_MCGFLAGS) --java-only " ++
                    ModuleArg ++ " $(ERR_REDIRECT)"])
        ]
    ).

%---------------------------------------------------------------------------%

:- pred gather_fim_specs_in_ancestor_int_spec(ancestor_int_spec::in,
    set(fim_spec)::in, set(fim_spec)::out) is det.

gather_fim_specs_in_ancestor_int_spec(AncestorIntSpec, !FIMSpecs) :-
    AncestorIntSpec = ancestor_int0(ParseTreeInt0, _ReadWhy0),
    gather_fim_specs_in_parse_tree_int0(ParseTreeInt0, !FIMSpecs).

:- pred gather_fim_specs_in_direct_int_spec(direct_int_spec::in,
    set(fim_spec)::in, set(fim_spec)::out) is det.

gather_fim_specs_in_direct_int_spec(DirectIntSpec, !FIMSpecs) :-
    (
        DirectIntSpec = direct_int1(ParseTreeInt1, _ReadWhy1),
        gather_fim_specs_in_parse_tree_int1(ParseTreeInt1, !FIMSpecs)
    ;
        DirectIntSpec = direct_int3(_ParseTreeInt3, _ReadWhy3)
        % .int3 files cannot contain FIMs.
    ).

:- pred gather_fim_specs_in_indirect_int_spec(indirect_int_spec::in,
    set(fim_spec)::in, set(fim_spec)::out) is det.

gather_fim_specs_in_indirect_int_spec(IndirectIntSpec, !FIMSpecs) :-
    (
        IndirectIntSpec = indirect_int2(ParseTreeInt2, _ReadWhy2),
        gather_fim_specs_in_parse_tree_int2(ParseTreeInt2, !FIMSpecs)
    ;
        IndirectIntSpec = indirect_int3(_ParseTreeInt3, _ReadWhy3)
        % .int3 files cannot contain FIMs.
    ).

:- pred gather_fim_specs_in_int_for_opt_spec(int_for_opt_spec::in,
    set(fim_spec)::in, set(fim_spec)::out) is det.

gather_fim_specs_in_int_for_opt_spec(IntForOptSpec, !FIMSpecs) :-
    (
        IntForOptSpec = for_opt_int0(ParseTreeInt0, _ReadWhy0),
        gather_fim_specs_in_parse_tree_int0(ParseTreeInt0, !FIMSpecs)
    ;
        IntForOptSpec = for_opt_int1(ParseTreeInt1, _ReadWhy1),
        gather_fim_specs_in_parse_tree_int1(ParseTreeInt1, !FIMSpecs)
    ;
        IntForOptSpec = for_opt_int2(ParseTreeInt2, _ReadWhy2),
        gather_fim_specs_in_parse_tree_int2(ParseTreeInt2, !FIMSpecs)
    ).

:- pred gather_fim_specs_in_parse_tree_int0(parse_tree_int0::in,
    set(fim_spec)::in, set(fim_spec)::out) is det.

gather_fim_specs_in_parse_tree_int0(ParseTreeInt0, !FIMSpecs) :-
    IntFIMS = ParseTreeInt0 ^ pti0_int_fims,
    ImpFIMS = ParseTreeInt0 ^ pti0_imp_fims,
    !:FIMSpecs = set.union_list([IntFIMS, ImpFIMS, !.FIMSpecs]).

:- pred gather_fim_specs_in_parse_tree_int1(parse_tree_int1::in,
    set(fim_spec)::in, set(fim_spec)::out) is det.

gather_fim_specs_in_parse_tree_int1(ParseTreeInt1, !FIMSpecs) :-
    IntFIMS = ParseTreeInt1 ^ pti1_int_fims,
    ImpFIMS = ParseTreeInt1 ^ pti1_imp_fims,
    !:FIMSpecs = set.union_list([IntFIMS, ImpFIMS, !.FIMSpecs]).

:- pred gather_fim_specs_in_parse_tree_int2(parse_tree_int2::in,
    set(fim_spec)::in, set(fim_spec)::out) is det.

gather_fim_specs_in_parse_tree_int2(ParseTreeInt2, !FIMSpecs) :-
    IntFIMS = ParseTreeInt2 ^ pti2_int_fims,
    ImpFIMS = ParseTreeInt2 ^ pti2_imp_fims,
    !:FIMSpecs = set.union_list([IntFIMS, ImpFIMS, !.FIMSpecs]).

:- pred gather_fim_specs_in_parse_tree_plain_opt(parse_tree_plain_opt::in,
    set(fim_spec)::in, set(fim_spec)::out) is det.

gather_fim_specs_in_parse_tree_plain_opt(ParseTreePlainOpt, !FIMSpecs) :-
    set.union(ParseTreePlainOpt ^ ptpo_fims, !FIMSpecs).

%---------------------------------------------------------------------------%

:- pred gather_nested_deps(globals::in, module_name::in, list(module_name)::in,
    other_ext::in, mmake_entry::out, io::di, io::uo) is det.

gather_nested_deps(Globals, ModuleName, NestedDeps, OtherExt,
        MmakeRule, !IO) :-
    module_name_to_file_name(Globals, $pred, do_not_create_dirs,
        ext_other(OtherExt), ModuleName, ModuleExtName, !IO),
    make_module_file_names_with_suffix(Globals,
        ext_other(OtherExt), NestedDeps, NestedDepsFileNames, !IO),
    ExtStr = other_extension_to_string(OtherExt),
    MmakeRule = mmake_simple_rule("nested_deps_for_" ++ ExtStr,
        mmake_rule_is_not_phony,
        ModuleExtName,
        NestedDepsFileNames,
        []).

:- pred gather_foreign_import_deps(globals::in, other_ext::in,
    list(module_name)::in, string::in, mmake_entry::out,
    io::di, io::uo) is det.

gather_foreign_import_deps(Globals, ForeignImportOtherExt,
        ForeignImportedModuleNames, ForeignImportTarget, MmakeRule, !IO) :-
    make_module_file_names_with_suffix(Globals,
        ext_other(ForeignImportOtherExt),
        ForeignImportedModuleNames, ForeignImportedFileNames, !IO),
    ForeignImportExtStr = other_extension_to_string(ForeignImportOtherExt),
    MmakeRule = mmake_simple_rule("foreign_deps_for_" ++ ForeignImportExtStr,
        mmake_rule_is_not_phony,
        ForeignImportTarget,
        ForeignImportedFileNames,
        []).

%---------------------------------------------------------------------------%

:- pred make_module_file_names_with_suffix(globals::in,
    ext::in, list(module_name)::in, list(mmake_file_name)::out,
    io::di, io::uo) is det.

make_module_file_names_with_suffix(Globals, Ext,
        Modules, FileNames, !IO) :-
    list.map_foldl(
        module_name_to_file_name(Globals, $pred, do_not_create_dirs, Ext),
        Modules, FileNames, !IO).

:- pred make_module_file_name_group_with_suffix(globals::in, string::in,
    ext::in, set(module_name)::in, list(mmake_file_name_group)::out,
    io::di, io::uo) is det.

make_module_file_name_group_with_suffix(Globals, GroupName, Ext,
        Modules, Groups, !IO) :-
    list.map_foldl(
        module_name_to_file_name(Globals, $pred, do_not_create_dirs, Ext),
        set.to_sorted_list(Modules), FileNames, !IO),
    Groups = make_file_name_group(GroupName, FileNames).

%---------------------------------------------------------------------------%

:- func foreign_include_file_path_name(file_name, foreign_include_file_info)
    = string.

foreign_include_file_path_name(SourceFileName, IncludeFile) = IncludePath :-
    IncludeFile = foreign_include_file_info(_Lang, IncludeFileName),
    make_include_file_path(SourceFileName, IncludeFileName, IncludePath).

:- pred get_fact_table_dependencies(globals::in, other_ext::in,
    list(file_name)::in, list(string)::out, io::di, io::uo) is det.

get_fact_table_dependencies(_, _, [], [], !IO).
get_fact_table_dependencies(Globals, OtherExt,
        [ExtraLink | ExtraLinks], [FileName | FileNames], !IO) :-
    fact_table_file_name(Globals, $pred, do_not_create_dirs,
        OtherExt, ExtraLink, FileName, !IO),
    get_fact_table_dependencies(Globals, OtherExt,
        ExtraLinks, FileNames, !IO).

    % With `--use-subdirs', allow users to type `mmake module.c'
    % rather than `mmake Mercury/cs/module.c'.
    %
:- pred construct_subdirs_shorthand_rule(globals::in, module_name::in,
    other_ext::in, mmake_entry::out, io::di, io::uo) is det.

construct_subdirs_shorthand_rule(Globals, ModuleName, OtherExt,
        MmakeRule, !IO) :-
    module_name_to_file_name_stem(ModuleName, ModuleStr),
    module_name_to_file_name(Globals, $pred, do_not_create_dirs,
        ext_other(OtherExt), ModuleName, Target, !IO),
    ExtStr = other_extension_to_string(OtherExt),
    ShorthandTarget = ModuleStr ++ ExtStr,
    MmakeRule = mmake_simple_rule("subdir_shorthand_for_" ++ ExtStr,
        mmake_rule_is_phony, ShorthandTarget, [Target], []).

%---------------------------------------------------------------------------%

generate_dependencies_write_d_files(_, [], _, _, _, _, _, _, !IO).
generate_dependencies_write_d_files(Globals, [Dep | Deps],
        IntDepsGraph, ImpDepsGraph, IndirectDepsGraph, IndirectOptDepsGraph,
        TransOptOrder, DepsMap, !IO) :-
    generate_dependencies_write_d_file(Globals, Dep,
        IntDepsGraph, ImpDepsGraph, IndirectDepsGraph, IndirectOptDepsGraph,
        TransOptOrder, DepsMap, !IO),
    generate_dependencies_write_d_files(Globals, Deps,
        IntDepsGraph, ImpDepsGraph, IndirectDepsGraph, IndirectOptDepsGraph,
        TransOptOrder, DepsMap, !IO).

:- pred generate_dependencies_write_d_file(globals::in, deps::in,
    deps_graph::in, deps_graph::in, deps_graph::in, deps_graph::in,
    list(module_name)::in, deps_map::in, io::di, io::uo) is det.

generate_dependencies_write_d_file(Globals, Dep,
        IntDepsGraph, ImpDepsGraph, IndirectDepsGraph, IndirectOptDepsGraph,
        TransOptOrder, _DepsMap, !IO) :-
    % XXX The fact that _DepsMap is unused here may be a bug.
    %
    % XXX Updating !ModuleAndImports does not look a correct thing to do
    % in this predicate, since it doesn't actually process any module imports.
    some [!ModuleAndImports] (
        Dep = deps(_, !:ModuleAndImports),

        % Look up the interface/implementation/indirect dependencies
        % for this module from the respective dependency graphs,
        % and save them in the module_and_imports structure.

        module_and_imports_get_module_name(!.ModuleAndImports, ModuleName),
        get_dependencies_from_graph(IndirectOptDepsGraph, ModuleName,
            IndirectOptDepsMap),
        one_or_more_map.keys_as_set(IndirectOptDepsMap, IndirectOptDeps),

        globals.lookup_bool_option(Globals, intermodule_optimization,
            Intermod),
        (
            Intermod = yes,
            % Be conservative with inter-module optimization -- assume a
            % module depends on the `.int', `.int2' and `.opt' files
            % for all transitively imported modules.
            IntDepsMap = IndirectOptDepsMap,
            ImpDepsMap = IndirectOptDepsMap,
            IndirectDeps = IndirectOptDeps
        ;
            Intermod = no,
            get_dependencies_from_graph(IntDepsGraph, ModuleName, IntDepsMap),
            get_dependencies_from_graph(ImpDepsGraph, ModuleName, ImpDepsMap),
            get_dependencies_from_graph(IndirectDepsGraph, ModuleName,
                IndirectDepsMap),
            one_or_more_map.keys_as_set(IndirectDepsMap, IndirectDeps)
        ),

        % Assume we need the `.mh' files for all imported modules
        % (we will if they define foreign types).
        % XXX This overly conservative assumption can lead to a lot of
        % unnecessary recompilations.
        CSCsFIMs0 = init_foreign_import_modules,
        globals.get_target(Globals, Target),
        (
            Target = target_c,
            CSCsFIMs = CSCsFIMs0 ^ fim_c := IndirectOptDeps
        ;
            Target = target_csharp,
            CSCsFIMs = CSCsFIMs0 ^ fim_csharp := IndirectOptDeps
        ;
            Target = target_java,
            CSCsFIMs = CSCsFIMs0 ^ fim_java := IndirectOptDeps
        ),
        module_and_imports_set_int_deps_map(IntDepsMap, !ModuleAndImports),
        module_and_imports_set_imp_deps_map(ImpDepsMap, !ModuleAndImports),
        module_and_imports_set_indirect_deps(IndirectDeps, !ModuleAndImports),
        module_and_imports_set_c_j_cs_fims(CSCsFIMs, !ModuleAndImports),

        % Compute the trans-opt dependencies for this module. To avoid
        % the possibility of cycles, each module is only allowed to depend
        % on modules that occur later than it in the TransOptOrder.

        FindModule =
            ( pred(OtherModule::in) is semidet :-
                ModuleName \= OtherModule
            ),
        list.drop_while(FindModule, TransOptOrder, TransOptDeps0),
        ( if TransOptDeps0 = [_ | TransOptDeps1] then
            % The module was found in the list.
            TransOptDeps = TransOptDeps1
        else
            TransOptDeps = []
        ),

        % Note that even if a fatal error occured for one of the files
        % that the current Module depends on, a .d file is still produced,
        % even though it probably contains incorrect information.
        module_and_imports_get_errors(!.ModuleAndImports, Errors),
        set.intersect(Errors, fatal_read_module_errors, FatalErrors),
        ( if set.is_empty(FatalErrors) then
            write_dependency_file(Globals, !.ModuleAndImports, IndirectOptDeps,
                yes(TransOptDeps), !IO)
        else
            true
        )
    ).

:- pred get_dependencies_from_graph(deps_graph::in, module_name::in,
    module_names_contexts::out) is det.

get_dependencies_from_graph(DepsGraph0, ModuleName, Dependencies) :-
    digraph.add_vertex(ModuleName, ModuleKey, DepsGraph0, DepsGraph),
    digraph.lookup_key_set_from(DepsGraph, ModuleKey, DepsKeysSet),
    AddKeyDep =
        ( pred(Key::in, Deps0::in, Deps::out) is det :-
            digraph.lookup_vertex(DepsGraph, Key, Dep),
            one_or_more_map.add(Dep, term.context_init, Deps0, Deps)
        ),
    sparse_bitset.foldl(AddKeyDep, DepsKeysSet,
        one_or_more_map.init, Dependencies).

%---------------------------------------------------------------------------%

generate_dependencies_write_dv_file(Globals, SourceFileName, ModuleName,
        DepsMap, !IO) :-
    globals.lookup_bool_option(Globals, verbose, Verbose),
    module_name_to_file_name(Globals, $pred, do_create_dirs,
        ext_other(other_ext(".dv")), ModuleName, DvFileName, !IO),
    get_progress_output_stream(Globals, ModuleName, ProgressStream, !IO),
    string.format("%% Creating auto-dependency file `%s'...\n",
        [s(DvFileName)], CreatingMsg),
    maybe_write_string(ProgressStream, Verbose, CreatingMsg, !IO),
    io.open_output(DvFileName, DvResult, !IO),
    (
        DvResult = ok(DvStream),
        generate_dv_file(Globals, SourceFileName, ModuleName, DepsMap,
            MmakeFile, !IO),
        write_mmakefile(DvStream, MmakeFile, !IO),
        io.close_output(DvStream, !IO),
        maybe_write_string(ProgressStream, Verbose, "% done.\n", !IO)
    ;
        DvResult = error(IOError),
        maybe_write_string(ProgressStream, Verbose, " failed.\n", !IO),
        maybe_flush_output(ProgressStream, Verbose, !IO),
        get_error_output_stream(Globals, ModuleName, ErrorStream, !IO),
        io.error_message(IOError, IOErrorMessage),
        string.format("error opening file `%s' for output: %s",
            [s(DvFileName), s(IOErrorMessage)], DepMessage),
        report_error(ErrorStream, DepMessage, !IO)
    ).

%---------------------------------------------------------------------------%

:- pred generate_dv_file(globals::in, file_name::in, module_name::in,
    deps_map::in, mmakefile::out, io::di, io::uo) is det.

generate_dv_file(Globals, SourceFileName, ModuleName, DepsMap,
        MmakeFile, !IO) :-
    ModuleNameString = sym_name_to_string(ModuleName),
    library.version(Version, FullArch),
    MmakeStartComment = mmake_start_comment("dependency variables",
        ModuleNameString, SourceFileName, Version, FullArch),

    map.keys(DepsMap, Modules0),
    select_ok_modules(Modules0, DepsMap, Modules1),
    list.sort(compare_module_names, Modules1, Modules),

    module_name_to_make_var_name(ModuleName, ModuleMakeVarName),
    list.map(get_source_file(DepsMap), Modules, SourceFiles0),
    list.sort_and_remove_dups(SourceFiles0, SourceFiles),

    MmakeVarModuleMs = mmake_var_defn_list(ModuleMakeVarName ++ ".ms",
        list.map(add_suffix(".m"), SourceFiles)),

    MmakeVarModuleErrs = mmake_var_defn_list(ModuleMakeVarName ++ ".errs",
        list.map(add_suffix(".err"), SourceFiles)),

    make_module_file_names_with_suffix(Globals, ext_other(other_ext("")),
        Modules, ModulesSourceFileNames, !IO),
    MmakeVarModuleMods = mmake_var_defn_list(ModuleMakeVarName ++ ".mods",
        ModulesSourceFileNames),

    % The modules for which we need to generate .int0 files.
    ModulesWithSubModules = list.filter(
        ( pred(Module::in) is semidet :-
            map.lookup(DepsMap, Module, deps(_, ModuleAndImports)),
            module_and_imports_get_children_map(ModuleAndImports, ChildrenMap),
            not one_or_more_map.is_empty(ChildrenMap)
        ), Modules),

    make_module_file_names_with_suffix(Globals, ext_other(other_ext("")),
        ModulesWithSubModules, ModulesWithSubModulesSourceFileNames, !IO),
    MmakeVarModuleParentMods = mmake_var_defn_list(
        ModuleMakeVarName ++ ".parent_mods",
        ModulesWithSubModulesSourceFileNames),

    globals.get_target(Globals, Target),
    (
        ( Target = target_c
        ; Target = target_csharp
        ; Target = target_java
        ),
        ForeignModulesAndExts = []
    ),
    ForeignModules = assoc_list.keys(ForeignModulesAndExts),

    make_module_file_names_with_suffix(Globals, ext_other(other_ext("")),
        ForeignModules, ForeignModulesFileNames, !IO),
    MmakeVarForeignModules =
        mmake_var_defn_list(ModuleMakeVarName ++ ".foreign",
            ForeignModulesFileNames),

    MakeFileName =
        ( pred(M - E::in, F::out, IO0::di, IO::uo) is det :-
            module_name_to_file_name(Globals, $pred, do_create_dirs, E, M, F0,
                IO0, IO),
            F = "$(os_subdir)" ++ F0
        ),
    list.map_foldl(MakeFileName, ForeignModulesAndExts, ForeignFileNames, !IO),

    % .foreign_cs are the source files which have had foreign code placed
    % in them.
    % XXX This rule looks wrong: why are we looking for (a) stuff with an
    % unknown suffix in (b) the os_subdir, when we (c) refer to it
    % using a make variable whose name ends in "_cs"?
    % Of course, since ForeignModulesAndExts is always zero with our current
    % set of target languages, this does not matter.
    MmakeVarForeignFileNames =
        mmake_var_defn_list(ModuleMakeVarName ++ ".foreign_cs",
            ForeignFileNames),

    % The dlls that contain the foreign_code.
    MmakeVarForeignDlls = mmake_var_defn(ModuleMakeVarName ++ ".foreign_dlls",
        string.format("$(%s.foreign:%%=$(dlls_subdir)%%.dll)",
            [s(ModuleMakeVarName)])),
    MmakeVarInitCs = mmake_var_defn(ModuleMakeVarName ++ ".init_cs",
        string.format("$(%s.mods:%%=$(cs_subdir)%%.c)",
            [s(ModuleMakeVarName)])),
    MmakeVarAllCs = mmake_var_defn(ModuleMakeVarName ++ ".all_cs",
        string.format("$(%s.mods:%%=$(cs_subdir)%%.c)",
            [s(ModuleMakeVarName)])),

    get_fact_table_file_names(DepsMap, Modules, FactTableFileNames),
    % XXX EXT
    % We should just be able to append ".c", ".$O" and the pic extension
    % to each string in FactTableFileNames.
    get_fact_table_dependencies(Globals, other_ext(".c"),
        FactTableFileNames, FactTableFileNamesC, !IO),
    get_fact_table_dependencies(Globals, other_ext(".$O"),
        FactTableFileNames, FactTableFileNamesOs, !IO),
    get_fact_table_dependencies(Globals, other_ext(".$(EXT_FOR_PIC_OBJECTS)"),
        FactTableFileNames, FactTableFileNamesPicOs, !IO),

    MmakeVarCs = mmake_var_defn_list(ModuleMakeVarName ++ ".cs",
        ["$(" ++ ModuleMakeVarName ++ ".init_cs)" | FactTableFileNamesC]),
    MmakeVarDlls = mmake_var_defn(ModuleMakeVarName ++ ".dlls",
        string.format("$(%s.mods:%%=$(dlls_subdir)%%.dll)",
            [s(ModuleMakeVarName)])),
    MmakeVarAllOs = mmake_var_defn_list(ModuleMakeVarName ++ ".all_os",
        [string.format("$(%s.mods:%%=$(os_subdir)%%.$O)",
            [s(ModuleMakeVarName)]) |
        FactTableFileNamesOs]),
    MmakeVarAllPicOs = mmake_var_defn_list(ModuleMakeVarName ++ ".all_pic_os",
        [string.format("$(%s.mods:%%=$(os_subdir)%%.$(EXT_FOR_PIC_OBJECTS))",
            [s(ModuleMakeVarName)]) |
        FactTableFileNamesPicOs]),
    MmakeVarOs = mmake_var_defn(ModuleMakeVarName ++ ".os",
        string.format("$(%s.all_os)", [s(ModuleMakeVarName)])),
    MmakeVarPicOs = mmake_var_defn(ModuleMakeVarName ++ ".pic_os",
        string.format("$(%s.all_pic_os)", [s(ModuleMakeVarName)])),
    MmakeVarUseds = mmake_var_defn(ModuleMakeVarName ++ ".useds",
        string.format("$(%s.mods:%%=$(used_subdir)%%.used)",
            [s(ModuleMakeVarName)])),
    MmakeVarJavas = mmake_var_defn(ModuleMakeVarName ++ ".javas",
        string.format("$(%s.mods:%%=$(javas_subdir)%%.java)",
            [s(ModuleMakeVarName)])),
    MmakeVarAllJavas = mmake_var_defn(ModuleMakeVarName ++ ".all_javas",
        string.format("$(%s.mods:%%=$(javas_subdir)%%.java)",
            [s(ModuleMakeVarName)])),

    % The Java compiler creates a .class file for each class within the
    % original .java file. The filenames of all these can be matched with
    % `module\$*.class', hence the "\\$$*.class" below.
    % If no such files exist, Make will use the pattern verbatim,
    % so we enclose the pattern in a `wildcard' function to prevent this.
    MmakeVarClasses = mmake_var_defn_list(ModuleMakeVarName ++ ".classes",
        [string.format("$(%s.mods:%%=$(classes_subdir)%%.class)",
            [s(ModuleMakeVarName)]),
        string.format(
            "$(wildcard $(%s.mods:%%=$(classes_subdir)%%\\$$*.class))",
            [s(ModuleMakeVarName)])]),
    MmakeVarCss = mmake_var_defn(ModuleMakeVarName ++ ".css",
        string.format("$(%s.mods:%%=$(css_subdir)%%.cs)",
            [s(ModuleMakeVarName)])),
    MmakeVarAllCss = mmake_var_defn(ModuleMakeVarName ++ ".all_css",
        string.format("$(%s.mods:%%=$(css_subdir)%%.cs)",
            [s(ModuleMakeVarName)])),
    MmakeVarDirs = mmake_var_defn(ModuleMakeVarName ++ ".dirs",
        string.format("$(%s.mods:%%=$(dirs_subdir)%%.dir)",
            [s(ModuleMakeVarName)])),
    MmakeVarDirOs = mmake_var_defn(ModuleMakeVarName ++ ".dir_os",
        string.format("$(%s.mods:%%=$(dirs_subdir)%%.dir/*.$O)",
            [s(ModuleMakeVarName)])),
    MmakeVarDates = mmake_var_defn(ModuleMakeVarName ++ ".dates",
        string.format("$(%s.mods:%%=$(dates_subdir)%%.date)",
            [s(ModuleMakeVarName)])),
    MmakeVarDate0s = mmake_var_defn(ModuleMakeVarName ++ ".date0s",
        string.format("$(%s.mods:%%=$(date0s_subdir)%%.date0)",
            [s(ModuleMakeVarName)])),
    MmakeVarDate3s = mmake_var_defn(ModuleMakeVarName ++ ".date3s",
        string.format("$(%s.mods:%%=$(date3s_subdir)%%.date3)",
            [s(ModuleMakeVarName)])),
    MmakeVarOptDates = mmake_var_defn(ModuleMakeVarName ++ ".optdates",
        string.format("$(%s.mods:%%=$(optdates_subdir)%%.optdate)",
            [s(ModuleMakeVarName)])),
    MmakeVarTransOptDates =
        mmake_var_defn(ModuleMakeVarName ++ ".trans_opt_dates",
            string.format(
                "$(%s.mods:%%=$(trans_opt_dates_subdir)%%.trans_opt_date)",
                [s(ModuleMakeVarName)])),
    MmakeVarCDates = mmake_var_defn(ModuleMakeVarName ++ ".c_dates",
        string.format("$(%s.mods:%%=$(c_dates_subdir)%%.c_date)",
            [s(ModuleMakeVarName)])),
    MmakeVarJavaDates = mmake_var_defn(ModuleMakeVarName ++ ".java_dates",
        string.format("$(%s.mods:%%=$(java_dates_subdir)%%.java_date)",
            [s(ModuleMakeVarName)])),
    MmakeVarCsDates = mmake_var_defn(ModuleMakeVarName ++ ".cs_dates",
        string.format("$(%s.mods:%%=$(cs_dates_subdir)%%.cs_date)",
            [s(ModuleMakeVarName)])),
    MmakeVarDs = mmake_var_defn(ModuleMakeVarName ++ ".ds",
        string.format("$(%s.mods:%%=$(ds_subdir)%%.d)",
            [s(ModuleMakeVarName)])),

    % XXX Why is make_module_dep_file_extension a function?
    ModuleDepFileExt = make_module_dep_file_extension,
    ModuleDepFileExtStr = other_extension_to_string(ModuleDepFileExt),
    MmakeVarModuleDeps = mmake_var_defn(ModuleMakeVarName ++ ".module_deps",
        string.format("$(%s.mods:%%=$(module_deps_subdir)%%%s)",
            [s(ModuleMakeVarName), s(ModuleDepFileExtStr)])),

    (
        Target = target_c,
        globals.lookup_bool_option(Globals, highlevel_code, HighLevelCode),
        (
            HighLevelCode = yes,
            % For the high level C back-end, we generate a `.mih' file
            % for every module.
            MihSources = [string.format("$(%s.mods:%%=$(mihs_subdir)%%.mih)",
                [s(ModuleMakeVarName)])]
        ;
            HighLevelCode = no,
            % For the LLDS back-end, we don't use `.mih' files at all.
            MihSources = []
        ),
        % We use `.mh' files for both low and high level C backends.
        MhSources =
            [string.format("$(%s.mods:%%=%%.mh)", [s(ModuleMakeVarName)])]
    ;
        % We don't generate C header files for non-C backends.
        ( Target = target_csharp
        ; Target = target_java
        ),
        MihSources = [],
        MhSources = []
    ),
    MmakeVarMihs =
        mmake_var_defn_list(ModuleMakeVarName ++ ".mihs", MihSources),
    MmakeVarMhs = mmake_var_defn_list(ModuleMakeVarName ++ ".mhs", MhSources),

    % The `<module>.all_mihs' variable is like `<module>.mihs' except that
    % it contains header files for all the modules, regardless of the grade
    % or --target option. It is used by the rule for `mmake realclean',
    % which should remove anything that could have been automatically
    % generated, even if the grade or --target option has changed.
    MmakeVarAllMihs = mmake_var_defn(ModuleMakeVarName ++ ".all_mihs",
        string.format("$(%s.mods:%%=$(mihs_subdir)%%.mih)",
            [s(ModuleMakeVarName)])),

    % The `<module>.all_mhs' variable is like `<module>.mhs' except that
    % it contains header files for all the modules, as for `<module>.all_mihs'
    % above.
    MmakeVarAllMhs = mmake_var_defn(ModuleMakeVarName ++ ".all_mhs",
        string.format("$(%s.mods:%%=%%.mh)",
            [s(ModuleMakeVarName)])),

    MmakeVarInts = mmake_var_defn_list(ModuleMakeVarName ++ ".ints",
        [string.format("$(%s.mods:%%=$(ints_subdir)%%.int)",
            [s(ModuleMakeVarName)]),
        string.format("$(%s.mods:%%=$(int2s_subdir)%%.int2)",
            [s(ModuleMakeVarName)])]),
    % `.int0' files are only generated for modules with submodules.
    % XXX ... or at least they should be. Currently we end up generating
    % .int0 files for nested submodules that don't have any children.
    % (We do the correct thing for separate submodules.)
    MmakeVarInt0s = mmake_var_defn(ModuleMakeVarName ++ ".int0s",
        string.format("$(%s.parent_mods:%%=$(int0s_subdir)%%.int0)",
            [s(ModuleMakeVarName)])),
    % XXX The `<module>.all_int0s' variables is like `<module>.int0s' except
    % that it contains .int0 files for all modules, regardless of whether
    % they should have been created or not. It is used by the rule for
    % `mmake realclean' to ensure that we clean up all the .int0 files,
    % including the ones that were accidently created by the bug described
    % above.
    MmakeVarAllInt0s = mmake_var_defn(ModuleMakeVarName ++ ".all_int0s",
        string.format("$(%s.mods:%%=$(int0s_subdir)%%.int0)",
            [s(ModuleMakeVarName)])),
    MmakeVarInt3s = mmake_var_defn(ModuleMakeVarName ++ ".int3s",
        string.format("$(%s.mods:%%=$(int3s_subdir)%%.int3)",
            [s(ModuleMakeVarName)])),
    MmakeVarOpts = mmake_var_defn(ModuleMakeVarName ++ ".opts",
        string.format("$(%s.mods:%%=$(opts_subdir)%%.opt)",
            [s(ModuleMakeVarName)])),
    MmakeVarTransOpts = mmake_var_defn(ModuleMakeVarName ++ ".trans_opts",
        string.format("$(%s.mods:%%=$(trans_opts_subdir)%%.trans_opt)",
            [s(ModuleMakeVarName)])),
    MmakeVarAnalysiss = mmake_var_defn(ModuleMakeVarName ++ ".analysiss",
        string.format("$(%s.mods:%%=$(analysiss_subdir)%%.analysis)",
            [s(ModuleMakeVarName)])),
    MmakeVarRequests = mmake_var_defn(ModuleMakeVarName ++ ".requests",
        string.format("$(%s.mods:%%=$(requests_subdir)%%.request)",
            [s(ModuleMakeVarName)])),
    MmakeVarImdgs = mmake_var_defn(ModuleMakeVarName ++ ".imdgs",
        string.format("$(%s.mods:%%=$(imdgs_subdir)%%.imdg)",
            [s(ModuleMakeVarName)])),
    MmakeVarProfs = mmake_var_defn(ModuleMakeVarName ++ ".profs",
        string.format("$(%s.mods:%%=%%.prof)",
            [s(ModuleMakeVarName)])),

    MmakeEntries =
        [MmakeStartComment, MmakeVarModuleMs, MmakeVarModuleErrs,
        MmakeVarModuleMods, MmakeVarModuleParentMods,
        MmakeVarForeignModules, MmakeVarForeignFileNames, MmakeVarForeignDlls,
        MmakeVarInitCs, MmakeVarAllCs, MmakeVarCs, MmakeVarDlls,
        MmakeVarAllOs, MmakeVarAllPicOs, MmakeVarOs, MmakeVarPicOs,
        MmakeVarUseds,
        MmakeVarJavas, MmakeVarAllJavas, MmakeVarClasses,
        MmakeVarCss, MmakeVarAllCss,
        MmakeVarDirs, MmakeVarDirOs,
        MmakeVarDates, MmakeVarDate0s, MmakeVarDate3s,
        MmakeVarOptDates, MmakeVarTransOptDates,
        MmakeVarCDates, MmakeVarJavaDates, MmakeVarCsDates,
        MmakeVarDs, MmakeVarModuleDeps, MmakeVarMihs,
        MmakeVarMhs, MmakeVarAllMihs, MmakeVarAllMhs,
        MmakeVarInts, MmakeVarInt0s, MmakeVarAllInt0s, MmakeVarInt3s,
        MmakeVarOpts, MmakeVarTransOpts,
        MmakeVarAnalysiss, MmakeVarRequests, MmakeVarImdgs, MmakeVarProfs],
    MmakeFile = cord.from_list(
        list.map(mmake_entry_to_fragment, MmakeEntries)).

%---------------------%

:- pred select_ok_modules(list(module_name)::in, deps_map::in,
    list(module_name)::out) is det.

select_ok_modules([], _, []).
select_ok_modules([Module | Modules0], DepsMap, Modules) :-
    select_ok_modules(Modules0, DepsMap, ModulesTail),
    map.lookup(DepsMap, Module, deps(_, ModuleAndImports)),
    module_and_imports_get_errors(ModuleAndImports, Errors),
    set.intersect(Errors, fatal_read_module_errors, FatalErrors),
    ( if set.is_empty(FatalErrors) then
        Modules = [Module | ModulesTail]
    else
        Modules = ModulesTail
    ).

%---------------------%

    % get_fact_table_file_names(DepsMap, Modules, ExtraLinkObjs):
    %
    % Find any extra .$O files that should be linked into the executable.
    % These include fact table object files and object files for foreign
    % code that can't be generated inline for this target.
    %
:- pred get_fact_table_file_names(deps_map::in, list(module_name)::in,
    list(file_name)::out) is det.

get_fact_table_file_names(DepsMap, Modules, FactTableFileNames) :-
    % It is possible, though very unlikely, that two or more modules
    % depend on the same fact table.
    get_fact_table_file_names(DepsMap, Modules,
        set.init, FactTableFileNamesSet),
    set.to_sorted_list(FactTableFileNamesSet, FactTableFileNames).

:- pred get_fact_table_file_names(deps_map::in, list(module_name)::in,
    set(file_name)::in, set(file_name)::out) is det.

get_fact_table_file_names(_DepsMap, [], !FactTableFileNames).
get_fact_table_file_names(DepsMap, [Module | Modules], !FactTableFileNames) :-
    map.lookup(DepsMap, Module, deps(_, ModuleAndImports)),
    % Handle object files for fact tables.
    module_and_imports_get_fact_table_deps(ModuleAndImports, FactTableDeps),
    % Handle object files for foreign code.
    % NOTE: currently none of the backends support foreign code
    % in a non target language.
    set.insert_list(FactTableDeps, !FactTableFileNames),
    get_fact_table_file_names(DepsMap, Modules, !FactTableFileNames).

%---------------------------------------------------------------------------%

generate_dependencies_write_dep_file(Globals, SourceFileName, ModuleName,
        DepsMap, !IO) :-
    globals.lookup_bool_option(Globals, verbose, Verbose),
    module_name_to_file_name(Globals, $pred, do_create_dirs,
        ext_other(other_ext(".dep")), ModuleName, DepFileName, !IO),
    get_progress_output_stream(Globals, ModuleName, ProgressStream, !IO),
    string.format("%% Creating auto-dependency file `%s'...\n",
        [s(DepFileName)], CreatingMsg),
    maybe_write_string(ProgressStream, Verbose, CreatingMsg, !IO),
    io.open_output(DepFileName, DepResult, !IO),
    (
        DepResult = ok(DepStream),
        generate_dep_file(Globals, SourceFileName, ModuleName, DepsMap,
            MmakeFile, !IO),
        write_mmakefile(DepStream, MmakeFile, !IO),
        io.close_output(DepStream, !IO),
        maybe_write_string(ProgressStream, Verbose, "% done.\n", !IO)
    ;
        DepResult = error(IOError),
        maybe_write_string(ProgressStream, Verbose, " failed.\n", !IO),
        maybe_flush_output(ProgressStream, Verbose, !IO),
        get_error_output_stream(Globals, ModuleName, ErrorStream, !IO),
        io.error_message(IOError, IOErrorMessage),
        string.format("error opening file `%s' for output: %s",
            [s(DepFileName), s(IOErrorMessage)], DepMessage),
        report_error(ErrorStream, DepMessage, !IO)
    ).

%---------------------------------------------------------------------------%

:- type maybe_mmake_var == pair(list(string), string).

:- pred generate_dep_file(globals::in, file_name::in, module_name::in,
    deps_map::in, mmakefile::out, io::di, io::uo) is det.

generate_dep_file(Globals, SourceFileName, ModuleName, DepsMap,
        !:MmakeFile, !IO) :-
    ModuleNameString = sym_name_to_string(ModuleName),
    library.version(Version, FullArch),

    MmakeStartComment = mmake_start_comment("program dependencies",
        ModuleNameString, SourceFileName, Version, FullArch),

    module_name_to_make_var_name(ModuleName, ModuleMakeVarName),

    module_name_to_file_name(Globals, $pred, do_create_dirs,
        ext_other(other_ext(".init")), ModuleName, InitFileName, !IO),
    module_name_to_file_name(Globals, $pred, do_create_dirs,
        ext_other(other_ext("_init.c")), ModuleName, InitCFileName, !IO),
    module_name_to_file_name(Globals, $pred, do_create_dirs,
        ext_other(other_ext("_init.$O")), ModuleName, InitObjFileName, !IO),
    module_name_to_file_name(Globals, $pred, do_create_dirs,
        ext_other(other_ext("_init.pic_o")),
        ModuleName, InitPicObjFileName, !IO),

    globals.lookup_bool_option(Globals, generate_mmc_make_module_dependencies,
        MmcMakeDeps),
    globals.lookup_bool_option(Globals, intermodule_optimization, Intermod),
    globals.lookup_bool_option(Globals, transitive_optimization, TransOpt),
    (
        MmcMakeDeps = yes,
        ModuleDepsVar = "$(" ++ ModuleMakeVarName ++ ".module_deps)",
        MaybeModuleDepsVar = [ModuleDepsVar],
        MaybeModuleDepsVarSpace = ModuleDepsVar ++ " "
    ;
        MmcMakeDeps = no,
        MaybeModuleDepsVar = [],
        MaybeModuleDepsVarSpace = ""
    ),
    (
        Intermod = yes,
        OptsVar = "$(" ++ ModuleMakeVarName ++ ".opts)",
        MaybeOptsVar = [OptsVar],
        MaybeOptsVarSpace = OptsVar ++ " "
    ;
        Intermod = no,
        MaybeOptsVar = [],
        MaybeOptsVarSpace = ""
    ),
    (
        TransOpt = yes,
        TransOptsVar = "$(" ++ ModuleMakeVarName ++ ".trans_opts)",
        MaybeTransOptsVar = [TransOptsVar],
        MaybeTransOptsVarSpace = TransOptsVar ++ " "
    ;
        TransOpt = no,
        MaybeTransOptsVar = [],
        MaybeTransOptsVarSpace = ""
    ),
    MaybeModuleDepsVarPair = MaybeModuleDepsVar - MaybeModuleDepsVarSpace,
    MaybeOptsVarPair = MaybeOptsVar - MaybeOptsVarSpace,
    MaybeTransOptsVarPair = MaybeTransOptsVar - MaybeTransOptsVarSpace,

    start_mmakefile(!:MmakeFile),
    add_mmake_entry(MmakeStartComment, !MmakeFile),
    generate_dep_file_exec_library_targets(Globals, ModuleName,
        ModuleMakeVarName, InitFileName, InitObjFileName,
        MaybeOptsVar, MaybeTransOptsVar,
        ExeFileName, JarFileName, LibFileName, SharedLibFileName,
        !MmakeFile, !IO),
    generate_dep_file_init_targets(Globals, ModuleName, ModuleMakeVarName,
        InitCFileName, InitFileName, DepFileName, DvFileName, !MmakeFile, !IO),
    generate_dep_file_install_targets(Globals, ModuleName, DepsMap,
        ModuleMakeVarName, MmcMakeDeps, Intermod, TransOpt,
        MaybeModuleDepsVarPair, MaybeOptsVarPair, MaybeTransOptsVarPair,
        !MmakeFile, !IO),
    generate_dep_file_collective_targets(Globals, ModuleName,
        ModuleMakeVarName, !MmakeFile, !IO),
    generate_dep_file_clean_targets(Globals, ModuleName, ModuleMakeVarName,
        ExeFileName, InitCFileName, InitObjFileName, InitPicObjFileName,
        InitFileName, LibFileName, SharedLibFileName, JarFileName,
        DepFileName, DvFileName, !MmakeFile, !IO).

:- pred generate_dep_file_exec_library_targets(globals::in,
    module_name::in, string::in, string::in, string::in,
    list(string)::in, list(string)::in,
    string::out, string::out, string::out, string::out,
    mmakefile::in, mmakefile::out, io::di, io::uo) is det.

generate_dep_file_exec_library_targets(Globals, ModuleName,
        ModuleMakeVarName, InitFileName, InitObjFileName,
        MaybeOptsVar, MaybeTransOptsVar,
        ExeFileName, JarFileName, LibFileName, SharedLibFileName,
        !MmakeFile, !IO) :-
    module_name_to_file_name(Globals, $pred, do_not_create_dirs,
        ext_other(other_ext("")), ModuleName, ExeFileName, !IO),
    MmakeRuleExtForExe = mmake_simple_rule("ext_for_exe",
        mmake_rule_is_phony,
        ExeFileName,
        [ExeFileName ++ "$(EXT_FOR_EXE)"],
        []),
    MmakeFragmentExtForExe = mmf_conditional_fragments(
        mmake_cond_strings_not_equal("$(EXT_FOR_EXE)", ""),
        [mmf_entry(MmakeRuleExtForExe)], []),

    % Note we have to do some ``interesting'' hacks to get
    % `$(ALL_MLLIBS_DEP)' to work in the dependency list,
    % without getting complaints about undefined variables.
    All_MLLibsDep =
        "$(foreach @," ++ ModuleMakeVarName ++ ",$(ALL_MLLIBS_DEP))",
    All_MLObjs =
        "$(foreach @," ++ ModuleMakeVarName ++ ",$(ALL_MLOBJS))",
    All_MLPicObjs =
        "$(patsubst %.o,%.$(EXT_FOR_PIC_OBJECTS)," ++
        "$(foreach @," ++ ModuleMakeVarName ++ ",$(ALL_MLOBJS)))",

    NL_All_MLObjs = "\\\n\t\t" ++ All_MLObjs,

    % When compiling to C, we want to include $(foo.cs) first in
    % the dependency list, before $(foo.os).
    % This is not strictly necessary, since the .$O files themselves depend
    % on the .c files, but want to do it to ensure that Make will try to
    % create all the C files first, thus detecting errors early,
    % rather than first spending time compiling C files to .$O,
    % which could be a waste of time if the program contains errors.

    ModuleMakeVarNameClasses = "$(" ++ ModuleMakeVarName ++ ".classes)",

    ModuleMakeVarNameOs = "$(" ++ ModuleMakeVarName ++ ".os)",
    NonJavaMainRuleAction1Line1 =
        "$(ML) $(ALL_GRADEFLAGS) $(ALL_MLFLAGS) -- $(ALL_LDFLAGS) " ++
            "$(EXEFILE_OPT)" ++ ExeFileName ++ "$(EXT_FOR_EXE) " ++
            InitObjFileName ++ " \\",
    NonJavaMainRuleAction1Line2 =
        "\t" ++ ModuleMakeVarNameOs ++ " " ++ NL_All_MLObjs ++
            " $(ALL_MLLIBS)",
    MmakeRuleExecutableJava = mmake_simple_rule("executable_java",
        mmake_rule_is_not_phony,
        ExeFileName,
        [ModuleMakeVarNameClasses],
        []),
    MmakeRuleExecutableNonJava = mmake_simple_rule("executable_non_java",
        mmake_rule_is_not_phony,
        ExeFileName ++ "$(EXT_FOR_EXE)",
        [ModuleMakeVarNameOs, InitObjFileName, All_MLObjs, All_MLLibsDep],
        [NonJavaMainRuleAction1Line1, NonJavaMainRuleAction1Line2]),
    MmakeFragmentExecutable = mmf_conditional_entry(
        mmake_cond_grade_has_component("java"),
        MmakeRuleExecutableJava, MmakeRuleExecutableNonJava),

    module_name_to_lib_file_name(Globals, $pred, do_not_create_dirs,
        "lib", other_ext(""), ModuleName, LibTargetName, !IO),
    module_name_to_lib_file_name(Globals, $pred, do_create_dirs,
        "lib", other_ext(".$A"), ModuleName, LibFileName, !IO),
    module_name_to_lib_file_name(Globals, $pred, do_create_dirs,
        "lib", other_ext(".$(EXT_FOR_SHARED_LIB)"),
        ModuleName, SharedLibFileName, !IO),
    module_name_to_lib_file_name(Globals, $pred, do_not_create_dirs,
        "lib", other_ext(".$(EXT_FOR_SHARED_LIB)"),
        ModuleName, MaybeSharedLibFileName, !IO),
    module_name_to_file_name(Globals, $pred, do_not_create_dirs,
        ext_other(other_ext(".jar")), ModuleName, JarFileName, !IO),

    % Set up the installed name for shared libraries.

    globals.lookup_bool_option(Globals, shlib_linker_use_install_name,
        UseInstallName),
    (
        UseInstallName = yes,
        get_install_name_option(Globals, SharedLibFileName, InstallNameOpt)
    ;
        UseInstallName = no,
        InstallNameOpt = ""
    ),

    ModuleMakeVarNameInts = "$(" ++ ModuleMakeVarName ++ ".ints)",
    ModuleMakeVarNameInt3s = "$(" ++ ModuleMakeVarName ++ ".int3s)",
    AllIntSources = [ModuleMakeVarNameInts, ModuleMakeVarNameInt3s] ++
        MaybeOptsVar ++ MaybeTransOptsVar ++ [InitFileName],
    MmakeRuleLibTargetJava = mmake_simple_rule("lib_target_java",
        mmake_rule_is_phony,
        LibTargetName,
        [JarFileName | AllIntSources],
        []),
    MmakeRuleLibTargetNonJava = mmake_simple_rule("lib_target_non_java",
        mmake_rule_is_phony,
        LibTargetName,
        [LibFileName, MaybeSharedLibFileName | AllIntSources],
        []),
    MmakeFragmentLibTarget = mmf_conditional_entry(
        mmake_cond_grade_has_component("java"),
        MmakeRuleLibTargetJava, MmakeRuleLibTargetNonJava),

    ModuleMakeVarNamePicOs = "$(" ++ ModuleMakeVarName ++ ".pic_os)",
    SharedLibAction1Line1 =
        "$(ML) --make-shared-lib $(ALL_GRADEFLAGS) $(ALL_MLFLAGS) " ++
        "-- " ++ InstallNameOpt ++ " $(ALL_LD_LIBFLAGS) " ++
        "-o " ++ SharedLibFileName ++ " \\",
    SharedLibAction1Line2 = "\t" ++ ModuleMakeVarNamePicOs ++ " \\",
    SharedLibAction1Line3 = "\t" ++ All_MLPicObjs ++ " $(ALL_MLLIBS)",
    MmakeRuleSharedLib = mmake_simple_rule("shared_lib",
        mmake_rule_is_not_phony,
        SharedLibFileName,
        [ModuleMakeVarNamePicOs, All_MLPicObjs, All_MLLibsDep],
        [SharedLibAction1Line1, SharedLibAction1Line2, SharedLibAction1Line3]),
    MmakeFragmentSharedLib = mmf_conditional_fragments(
        mmake_cond_strings_not_equal("$(EXT_FOR_SHARED_LIB)", "$(A)"),
        [mmf_entry(MmakeRuleSharedLib)], []),

    LibAction1 = "rm -f " ++ LibFileName,
    LibAction2Line1 =
        "$(AR) $(ALL_ARFLAGS) $(AR_LIBFILE_OPT)" ++ LibFileName ++
            " " ++ ModuleMakeVarNameOs ++ " \\",
    LibAction2Line2 = "\t" ++ All_MLObjs,
    LibAction3 = "$(RANLIB) $(ALL_RANLIBFLAGS) " ++ LibFileName,
    MmakeRuleLib = mmake_simple_rule("lib",
        mmake_rule_is_not_phony,
        LibFileName,
        [ModuleMakeVarNameOs, All_MLObjs],
        [LibAction1, LibAction2Line1, LibAction2Line2, LibAction3]),

    list_class_files_for_jar_mmake(Globals, ModuleMakeVarNameClasses,
        ListClassFiles),
    JarAction1 = "$(JAR) $(JAR_CREATE_FLAGS) " ++ JarFileName ++ " " ++
        ListClassFiles,
    MmakeRuleJar = mmake_simple_rule("jar",
        mmake_rule_is_not_phony,
        JarFileName,
        [ModuleMakeVarNameClasses],
        [JarAction1]),

    add_mmake_fragment(MmakeFragmentExtForExe, !MmakeFile),
    add_mmake_fragment(MmakeFragmentExecutable, !MmakeFile),
    add_mmake_fragment(MmakeFragmentLibTarget, !MmakeFile),
    add_mmake_fragment(MmakeFragmentSharedLib, !MmakeFile),
    add_mmake_entries([MmakeRuleLib, MmakeRuleJar], !MmakeFile).

:- pred generate_dep_file_init_targets(globals::in,
    module_name::in, string::in, string::in, string::in,
    string::out, string::out,
    mmakefile::in, mmakefile::out, io::di, io::uo) is det.

generate_dep_file_init_targets(Globals, ModuleName, ModuleMakeVarName,
        InitCFileName, InitFileName, DepFileName, DvFileName,
        !MmakeFile, !IO) :-
    module_name_to_file_name(Globals, $pred, do_not_create_dirs,
        ext_other(other_ext(".dep")), ModuleName, DepFileName, !IO),
    module_name_to_file_name(Globals, $pred, do_not_create_dirs,
        ext_other(other_ext(".dv")), ModuleName, DvFileName, !IO),

    ModuleMakeVarNameCs = "$(" ++ ModuleMakeVarName ++ ".cs)",
    InitAction1 = "echo > " ++ InitFileName,
    InitAction2 = "$(MKLIBINIT) " ++ ModuleMakeVarNameCs ++
        " >> " ++ InitFileName,
    % $(EXTRA_INIT_COMMAND) should expand to a command to
    % generate extra entries in the `.init' file for a library.
    % It may expand to the empty string.
    InitAction3 = "$(EXTRA_INIT_COMMAND) >> " ++ InitFileName,
    MmakeRuleInitFile = mmake_simple_rule("init_file",
        mmake_rule_is_not_phony,
        InitFileName,
        [DepFileName, ModuleMakeVarNameCs],
        [InitAction1, InitAction2, InitAction3]),

    % The `force-module_init' dependency forces the commands for
    % the `module_init.c' rule to be run every time the rule
    % is considered.
    ModuleFileName = sym_name_to_string(ModuleName),
    ForceC2InitTarget = "force-" ++ ModuleFileName ++ "_init",
    MmakeRuleForceInitCFile = mmake_simple_rule("force_init_c_file",
        mmake_rule_is_not_phony,
        ForceC2InitTarget,
        [],
        []),

    TmpInitCFileName = InitCFileName ++ ".tmp",
    ModuleMakeVarNameInitCs = "$(" ++ ModuleMakeVarName ++ ".init_cs)",
    InitCAction1 =
        "@$(C2INIT) $(ALL_GRADEFLAGS) $(ALL_C2INITFLAGS) " ++
            "--init-c-file " ++ TmpInitCFileName ++ " " ++
            ModuleMakeVarNameInitCs ++ " $(ALL_C2INITARGS)",
    InitCAction2 = "@mercury_update_interface " ++ InitCFileName,
    MmakeRuleInitCFile = mmake_simple_rule("init_c_file",
        mmake_rule_is_not_phony,
        InitCFileName,
        [ForceC2InitTarget, ModuleMakeVarNameCs],
        [InitCAction1, InitCAction2]),

    add_mmake_entries(
        [MmakeRuleInitFile, MmakeRuleForceInitCFile, MmakeRuleInitCFile],
        !MmakeFile).

:- pred generate_dep_file_install_targets(globals::in, module_name::in,
    deps_map::in, string::in, bool::in, bool::in, bool::in,
    maybe_mmake_var::in, maybe_mmake_var::in, maybe_mmake_var::in,
    mmakefile::in, mmakefile::out, io::di, io::uo) is det.

generate_dep_file_install_targets(Globals, ModuleName, DepsMap,
        ModuleMakeVarName, MmcMakeDeps, Intermod, TransOpt,
        MaybeModuleDepsVarPair, MaybeOptsVarPair, MaybeTransOptsVarPair,
        !MmakeFile, !IO) :-
    % XXX  Note that we install the `.opt' and `.trans_opt' files
    % in two places: in the `lib/$(GRADE)/opts' directory, so
    % that mmc will find them, and also in the `ints' directory,
    % so that Mmake will find them. That is not ideal, but it works.

    MaybeOptsVarPair = MaybeOptsVar - MaybeOptsVarSpace,
    MaybeTransOptsVarPair = MaybeTransOptsVar - MaybeTransOptsVarSpace,
    MaybeModuleDepsVarPair = MaybeModuleDepsVar - MaybeModuleDepsVarSpace,

    module_name_to_lib_file_name(Globals, $pred, do_not_create_dirs,
        "lib", other_ext(".install_ints"), ModuleName,
        LibInstallIntsTargetName, !IO),
    module_name_to_lib_file_name(Globals, $pred, do_not_create_dirs,
        "lib", other_ext(".install_opts"), ModuleName,
        LibInstallOptsTargetName, !IO),
    module_name_to_lib_file_name(Globals, $pred, do_not_create_dirs,
        "lib", other_ext(".install_hdrs"), ModuleName,
        LibInstallHdrsTargetName, !IO),
    module_name_to_lib_file_name(Globals, $pred, do_not_create_dirs,
        "lib", other_ext(".install_grade_hdrs"), ModuleName,
        LibInstallGradeHdrsTargetName, !IO),

    ModuleMakeVarNameInts = "$(" ++ ModuleMakeVarName ++ ".ints)",
    ModuleMakeVarNameInt3s = "$(" ++ ModuleMakeVarName ++ ".int3s)",

    (
        Intermod = yes,
        MaybeSpaceOptStr = " opt"
    ;
        Intermod = no,
        MaybeSpaceOptStr = ""
    ),
    ( if
        Intermod = yes,
        some [ModuleAndImports] (
            map.member(DepsMap, _, deps(_, ModuleAndImports)),
            module_and_imports_get_children_map(ModuleAndImports, ChildrenMap),
            not one_or_more_map.is_empty(ChildrenMap)
        )
    then
        % The `.int0' files only need to be installed with
        % `--intermodule-optimization'.
        SpaceInt0Str = " int0",
        ModuleVarNameInt0s = "$(" ++ ModuleMakeVarName ++ ".int0s)",
        MaybeModuleVarNameInt0sSpace = ModuleVarNameInt0s ++ " ",
        MaybeModuleVarNameInt0s = [ModuleVarNameInt0s]
    else
        SpaceInt0Str = "",
        MaybeModuleVarNameInt0sSpace = "",
        MaybeModuleVarNameInt0s = []
    ),
    (
        TransOpt = yes,
        MaybeSpaceTransOptStr = " trans_opt"
    ;
        TransOpt = no,
        MaybeSpaceTransOptStr = ""
    ),
    (
        MmcMakeDeps = yes,
        MaybeSpaceDepStr = " module_dep"
    ;
        MmcMakeDeps = no,
        MaybeSpaceDepStr = ""
    ),

    LibInstallIntsFiles = """" ++
        ModuleMakeVarNameInts ++ " " ++ ModuleMakeVarNameInt3s ++ " " ++
        MaybeModuleVarNameInt0sSpace ++ MaybeOptsVarSpace ++
        MaybeTransOptsVarSpace ++ MaybeModuleDepsVarSpace ++ """",

    MmakeRuleLibInstallInts = mmake_simple_rule("lib_install_ints",
        mmake_rule_is_phony,
        LibInstallIntsTargetName,
        [ModuleMakeVarNameInts, ModuleMakeVarNameInt3s] ++
            MaybeModuleVarNameInt0s ++ MaybeOptsVar ++ MaybeTransOptsVar ++
            MaybeModuleDepsVar ++ ["install_lib_dirs"],
        ["files=" ++ LibInstallIntsFiles ++ "; \\",
        "for file in $$files; do \\",
        "\ttarget=""$(INSTALL_INT_DIR)/`basename $$file`""; \\",
        "\tif cmp -s ""$$file"" ""$$target""; then \\",
        "\t\techo \"$$target unchanged\"; \\",
        "\telse \\",
        "\t\techo \"installing $$target\"; \\",
        "\t\t$(INSTALL) ""$$file"" ""$$target""; \\",
        "\tfi; \\",
        "done",
        "# The following is needed to support the `--use-subdirs' option.",
        "# We try using `$(LN_S)', but if that fails, then we just use",
        "# `$(INSTALL)'.",
        "for ext in int int2 int3" ++
            SpaceInt0Str ++ MaybeSpaceOptStr ++ MaybeSpaceTransOptStr ++
            MaybeSpaceDepStr ++ "; do \\",
        "\tdir=""$(INSTALL_INT_DIR)/Mercury/$${ext}s""; \\",
        "\trm -rf ""$$dir""; \\",
        "\t$(LN_S) .. ""$$dir"" || { \\",
        "\t\t{ [ -d ""$$dir"" ] || \\",
        "\t\t$(INSTALL_MKDIR) ""$$dir""; } && \\",
        "\t\t$(INSTALL) ""$(INSTALL_INT_DIR)""/*.$$ext ""$$dir""; \\",
        "\t} || exit 1; \\",
        "done"]),

    ( if
        Intermod = no,
        TransOpt = no
    then
        LibInstallOptsSources = [],
        LibInstallOptsActions = [silent_noop_action]
    else
        LibInstallOptsSources = MaybeOptsVar ++ MaybeTransOptsVar ++
            ["install_grade_dirs"],
        LibInstallOptsFiles =
            """" ++ MaybeOptsVarSpace ++ MaybeTransOptsVarSpace ++ """",
        LibInstallOptsActions =
            ["files=" ++ LibInstallOptsFiles ++ "; \\",
            "for file in $$files; do \\",
            "\ttarget=""$(INSTALL_GRADE_INT_DIR)/`basename $$file`"";\\",
            "\tif cmp -s ""$$file"" ""$$target""; then \\",
            "\t\techo \"$$target unchanged\"; \\",
            "\telse \\",
            "\t\techo \"installing $$target\"; \\",
            "\t\t$(INSTALL) ""$$file"" ""$$target""; \\",
            "\tfi; \\",
            "done",
            "# The following is needed to support the `--use-subdirs' option",
            "# We try using `$(LN_S)', but if that fails, then we just use",
            "# `$(INSTALL)'.",
            "for ext in " ++ MaybeSpaceOptStr ++ MaybeSpaceTransOptStr ++
                "; do \\",
            "\tdir=""$(INSTALL_GRADE_INT_DIR)/Mercury/$${ext}s""; \\",
            "\trm -rf ""$$dir""; \\",
            "\t$(LN_S) .. ""$$dir"" || { \\",
            "\t\t{ [ -d ""$$dir"" ] || \\",
            "\t\t\t$(INSTALL_MKDIR) ""$$dir""; } && \\",
            "\t\t$(INSTALL) ""$(INSTALL_GRADE_INT_DIR)""/*.$$ext \\",
            "\t\t\t""$$dir""; \\",
            "\t} || exit 1; \\",
            "done"]
    ),
    MmakeRuleLibInstallOpts = mmake_simple_rule("lib_install_opts",
        mmake_rule_is_phony,
        LibInstallOptsTargetName,
        LibInstallOptsSources,
        LibInstallOptsActions),

    % XXX Note that we install the header files in two places:
    % in the `lib/inc' or `lib/$(GRADE)/$(FULLARCH)/inc' directory,
    % so that the C compiler will find them, and also in the `ints' directory,
    % so that Mmake will find them. That is not ideal, but it works.
    %
    % (A better fix would be to change the VPATH setting in
    % scripts/Mmake.vars.in so that Mmake also searches the
    % `lib/$(GRADE)/$(FULLARCH)/inc' directory, but doing that properly
    % is non-trivial.)

    ModuleMakeVarNameMhs = string.format("$(%s.mhs)", [s(ModuleMakeVarName)]),
    MmakeRuleLibInstallHdrsNoMhs = mmake_simple_rule("install_lib_hdrs_nomhs",
        mmake_rule_is_phony,
        LibInstallHdrsTargetName,
        [ModuleMakeVarNameMhs, "install_lib_dirs"],
        [silent_noop_action]),
    MmakeRuleLibInstallHdrsMhs = mmake_simple_rule("install_lib_hdrs_mhs",
        mmake_rule_is_phony,
        LibInstallHdrsTargetName,
        [ModuleMakeVarNameMhs, "install_lib_dirs"],
        ["for hdr in " ++ ModuleMakeVarNameMhs ++ "; do \\",
        "\t$(INSTALL) $$hdr $(INSTALL_INT_DIR); \\",
        "\t$(INSTALL) $$hdr $(INSTALL_INC_DIR); \\",
        "done"]),
    MmakeFragmentLibInstallHdrs = mmf_conditional_entry(
        mmake_cond_strings_equal(ModuleMakeVarNameMhs, ""),
        MmakeRuleLibInstallHdrsNoMhs,
        MmakeRuleLibInstallHdrsMhs),

    ModuleMakeVarNameMihs =
        string.format("$(%s.mihs)", [s(ModuleMakeVarName)]),
    MmakeRuleLibInstallGradeHdrsNoMihs = mmake_simple_rule(
        "install_grade_hdrs_no_mihs",
        mmake_rule_is_phony,
        LibInstallGradeHdrsTargetName,
        [ModuleMakeVarNameMihs, "install_grade_dirs"],
        [silent_noop_action]),
    MmakeRuleLibInstallGradeHdrsMihs = mmake_simple_rule(
        "install_grade_hdrs_mihs",
        mmake_rule_is_phony,
        LibInstallGradeHdrsTargetName,
        [ModuleMakeVarNameMihs, "install_grade_dirs"],
        ["for hdr in " ++ ModuleMakeVarNameMihs ++ "; do \\",
        "\t$(INSTALL) $$hdr $(INSTALL_INT_DIR); \\",
        "\t$(INSTALL) $$hdr $(INSTALL_GRADE_INC_DIR); \\",
        "done",
        "# The following is needed to support the `--use-subdirs' option.",
        "# We try using `$(LN_S)', but if that fails, then we just use",
        "# `$(INSTALL)'.",
        "rm -rf $(INSTALL_GRADE_INC_SUBDIR)",
        "$(LN_S) .. $(INSTALL_GRADE_INC_SUBDIR) || { \\",
        "\t{ [ -d $(INSTALL_GRADE_INC_SUBDIR) ] || \\",
        "\t\t$(INSTALL_MKDIR) $(INSTALL_GRADE_INC_SUBDIR); \\",
        "\t} && \\",
        "\t$(INSTALL) $(INSTALL_GRADE_INC_DIR)/*.mih \\",
        "\t\t$(INSTALL_GRADE_INC_SUBDIR); \\",
        "} || exit 1",
        "rm -rf $(INSTALL_INT_DIR)/Mercury/mihs",
        "$(LN_S) .. $(INSTALL_INT_DIR)/Mercury/mihs || { \\",
        "\t{ [ -d $(INSTALL_INT_DIR)/Mercury/mihs ] || \\",
        "\t\t$(INSTALL_MKDIR) \\",
        "\t\t$(INSTALL_INT_DIR)/Mercury/mihs; \\",
        "\t} && \\",
        "\t$(INSTALL) $(INSTALL_GRADE_INC_DIR)/*.mih \\",
        "\t\t$(INSTALL_INT_DIR); \\",
        "} || exit 1"]),
    MmakeFragmentLibInstallGradeHdrs = mmf_conditional_entry(
        mmake_cond_strings_equal(ModuleMakeVarNameMihs, ""),
        MmakeRuleLibInstallGradeHdrsNoMihs,
        MmakeRuleLibInstallGradeHdrsMihs),

    add_mmake_entry(MmakeRuleLibInstallInts, !MmakeFile),
    add_mmake_entry(MmakeRuleLibInstallOpts, !MmakeFile),
    add_mmake_fragment(MmakeFragmentLibInstallHdrs, !MmakeFile),
    add_mmake_fragment(MmakeFragmentLibInstallGradeHdrs, !MmakeFile).

:- pred generate_dep_file_collective_targets(globals::in,
    module_name::in, string::in,
    mmakefile::in, mmakefile::out, io::di, io::uo) is det.

generate_dep_file_collective_targets(Globals, ModuleName,
        ModuleMakeVarName, !MmakeFile, !IO) :-
    list.map_foldl(
        generate_dep_file_collective_target(Globals, ModuleName,
            ModuleMakeVarName),
        [
            ext_other(other_ext(".check")) - ".errs",
            ext_other(other_ext(".ints")) - ".dates",
            ext_other(other_ext(".int3s")) - ".date3s",
            ext_other(other_ext(".opts")) - ".optdates",
            ext_other(other_ext(".trans_opts")) - ".trans_opt_dates",
            ext_other(other_ext(".javas")) - ".javas",
            ext_other(other_ext(".classes")) - ".classes",
            ext_other(other_ext(".all_ints")) - ".dates",
            ext_other(other_ext(".all_int3s")) - ".date3s",
            ext_other(other_ext(".all_opts")) - ".optdates",
            ext_other(other_ext(".all_trans_opts")) - ".trans_opt_dates"
        ], MmakeRules, !IO),
    add_mmake_entries(MmakeRules, !MmakeFile).

:- pred generate_dep_file_collective_target(globals::in,
    module_name::in, string::in, pair(ext, string)::in,
    mmake_entry::out, io::di, io::uo) is det.

generate_dep_file_collective_target(Globals, ModuleName, ModuleMakeVarName,
        Ext - VarExtension, MmakeRule, !IO) :-
    module_name_to_file_name(Globals, $pred, do_not_create_dirs, Ext,
        ModuleName, TargetName, !IO),
    Source = string.format("$(%s%s)", [s(ModuleMakeVarName), s(VarExtension)]),
    ExtStr = extension_to_string(Ext),
    MmakeRule = mmake_simple_rule(
        "collective_target_" ++ ExtStr ++ VarExtension, mmake_rule_is_phony,
        TargetName, [Source], []).

:- pred generate_dep_file_clean_targets(globals::in,
    module_name::in, string::in, string::in, string::in,
    string::in, string::in, string::in, string::in, string::in, string::in,
    string::in, string::in,
    mmakefile::in, mmakefile::out, io::di, io::uo) is det.

generate_dep_file_clean_targets(Globals, ModuleName, ModuleMakeVarName,
        ExeFileName, InitCFileName, InitObjFileName, InitPicObjFileName,
        InitFileName, LibFileName, SharedLibFileName, JarFileName,
        DepFileName, DvFileName, !MmakeFile, !IO) :-
    % If you change the clean targets below, please also update the
    % documentation in doc/user_guide.texi.

    module_name_to_file_name(Globals, $pred, do_not_create_dirs,
        ext_other(other_ext(".clean")),
        ModuleName, CleanTargetName, !IO),
    module_name_to_file_name(Globals, $pred, do_not_create_dirs,
        ext_other(other_ext(".realclean")),
        ModuleName, RealCleanTargetName, !IO),

    % XXX Put these into a logical order.
    CleanSuffixes = [".dirs", ".cs", ".mihs", ".all_os", ".all_pic_os",
        ".c_dates", ".java_dates", ".useds", ".javas", ".profs",
        ".errs", ".foreign_cs"],
    CleanFiles = [InitCFileName, InitObjFileName, InitPicObjFileName],
    MmakeRulesClean =
        % XXX Why is the first rule not phony?
        [mmake_simple_rule("clean_local", mmake_rule_is_not_phony,
            "clean_local", [CleanTargetName], []),
        mmake_simple_rule("clean_target", mmake_rule_is_phony,
            CleanTargetName,
            [],
            list.map(remove_suffix_files_cmd(ModuleMakeVarName),
                CleanSuffixes) ++
            [remove_files_cmd(CleanFiles)])],

    % XXX We delete $(ModuleMakeVarName).all_int0s instead of
    % $(ModuleMakeVarName).int0s to make sure that we delete
    % any spurious .int0 files created for nested submodules.
    % For further details, see the XXX comments above.
    RealCleanSuffixes = [".dates", ".date0s", ".date3s",
        ".optdates", ".trans_opt_dates", ".ints", ".all_int0s", ".int3s",
        ".opts", ".trans_opts", ".analysiss", ".requests", ".imdgs",
        ".ds", ".module_deps", ".all_mhs", ".all_mihs", ".dlls",
        ".foreign_dlls", ".classes"],
    RealCleanFiles = [ExeFileName ++ "$(EXT_FOR_EXE) ", InitFileName,
        LibFileName, SharedLibFileName, JarFileName, DepFileName, DvFileName],
    MmakeRulesRealClean =
        % XXX Why is the first rule not phony?
        [mmake_simple_rule("realclean_local", mmake_rule_is_not_phony,
            "realclean_local", [RealCleanTargetName], []),
        mmake_simple_rule("realclean_target", mmake_rule_is_phony,
            RealCleanTargetName,
            [CleanTargetName],
            list.map(remove_suffix_files_cmd(ModuleMakeVarName),
                RealCleanSuffixes) ++
            [remove_files_cmd(RealCleanFiles)])],

    add_mmake_entries(MmakeRulesClean ++ MmakeRulesRealClean, !MmakeFile).

    % remove_suffix_files_cmd(ModuleMakeVarName, Extension):
    %
    % Return a command to delete the files in $(ModuleMakeVarNameExtension).
    %
    % XXX Xargs doesn't handle special characters in the file names correctly.
    % This is currently not a problem in practice as we never generate
    % file names containing special characters.
    %
    % Any fix for this problem will also require a fix in `mmake.in'.
    %
:- func remove_suffix_files_cmd(string, string) = string.

remove_suffix_files_cmd(ModuleMakeVarName, Extension) =
    string.format("-echo $(%s%s) | xargs rm -f",
        [s(ModuleMakeVarName), s(Extension)]).

:- func remove_files_cmd(list(string)) = string.

remove_files_cmd(Files) =
    "-rm -f " ++ string.join_list(" ", Files).

%---------------------------------------------------------------------------%

:- pred get_source_file(deps_map::in, module_name::in, file_name::out) is det.

get_source_file(DepsMap, ModuleName, FileName) :-
    map.lookup(DepsMap, ModuleName, Deps),
    Deps = deps(_, ModuleAndImports),
    module_and_imports_get_source_file_name(ModuleAndImports, SourceFileName),
    ( if string.remove_suffix(SourceFileName, ".m", SourceFileBase) then
        FileName = SourceFileBase
    else
        unexpected($pred, "source file name doesn't end in `.m'")
    ).

%---------------------------------------------------------------------------%

maybe_output_module_order(Globals, ModuleName, DepsOrdering, !IO) :-
    globals.lookup_bool_option(Globals, generate_module_order, Order),
    (
        Order = yes,
        module_name_to_file_name(Globals, $pred, do_create_dirs,
            ext_other(other_ext(".order")), ModuleName, OrdFileName, !IO),
        get_progress_output_stream(Globals, ModuleName, ProgressStream, !IO),
        globals.lookup_bool_option(Globals, verbose, Verbose),
        string.format("%% Creating module order file `%s'...",
            [s(OrdFileName)], CreatingMsg),
        maybe_write_string(ProgressStream, Verbose, CreatingMsg, !IO),
        io.open_output(OrdFileName, OrdResult, !IO),
        (
            OrdResult = ok(OrdStream),
            io.write_list(OrdStream, DepsOrdering, "\n\n",
                write_module_scc(OrdStream), !IO),
            io.close_output(OrdStream, !IO),
            maybe_write_string(ProgressStream, Verbose, " done.\n", !IO)
        ;
            OrdResult = error(IOError),
            maybe_write_string(ProgressStream, Verbose, " failed.\n", !IO),
            maybe_flush_output(ProgressStream, Verbose, !IO),
            get_error_output_stream(Globals, ModuleName, ErrorStream, !IO),
            io.error_message(IOError, IOErrorMessage),
            string.format("error opening file `%s' for output: %s",
                [s(OrdFileName), s(IOErrorMessage)], OrdMessage),
            report_error(ErrorStream, OrdMessage, !IO)
        )
    ;
        Order = no
    ).

:- pred write_module_scc(io.output_stream::in, set(module_name)::in,
    io::di, io::uo) is det.

write_module_scc(Stream, SCC0, !IO) :-
    set.to_sorted_list(SCC0, SCC),
    % XXX This is suboptimal (the stream should be specified once, not twice),
    % but in the absence of a test case, I (zs) am leaving it alone for now.
    io.write_list(Stream, SCC, "\n", prog_out.write_sym_name(Stream), !IO).

%---------------------------------------------------------------------------%

    % get_both_opt_deps(Globals, BuildOptFiles, Deps, IntermodDirs,
    %   OptDeps, TransOptDeps, !IO):
    %
    % For each dependency, search intermod_directories for a .m file.
    % If it exists, add it to both output lists. Otherwise, if a .opt
    % file exists, add it to the OptDeps list, and if a .trans_opt
    % file exists, add it to the TransOptDeps list.
    % If --use-opt-files is set, don't look for `.m' files, since we are
    % not building `.opt' files, only using those which are available.
    % XXX This won't find nested submodules.
    % XXX Use `mmc --make' if that matters.
    %
:- pred get_both_opt_deps(globals::in, bool::in, list(string)::in,
    list(module_name)::in, list(module_name)::out, list(module_name)::out,
    io::di, io::uo) is det.

get_both_opt_deps(_, _, _, [], [], [], !IO).
get_both_opt_deps(Globals, BuildOptFiles, IntermodDirs, [Dep | Deps],
        !:OptDeps, !:TransOptDeps, !IO) :-
    get_both_opt_deps(Globals, BuildOptFiles, IntermodDirs, Deps,
        !:OptDeps, !:TransOptDeps, !IO),
    (
        BuildOptFiles = yes,
        search_for_module_source(IntermodDirs, Dep, MaybeFileName, !IO),
        (
            MaybeFileName = ok(_),
            !:OptDeps = [Dep | !.OptDeps],
            !:TransOptDeps = [Dep | !.TransOptDeps],
            Found = yes
        ;
            MaybeFileName = error(_),
            Found = no
        )
    ;
        BuildOptFiles = no,
        Found = no
    ),
    (
        Found = no,
        module_name_to_file_name(Globals, $pred, do_not_create_dirs,
            ext_other(other_ext(".opt")), Dep, OptName, !IO),
        search_for_file_returning_dir(IntermodDirs, OptName, MaybeOptDir, !IO),
        (
            MaybeOptDir = ok(_),
            !:OptDeps = [Dep | !.OptDeps]
        ;
            MaybeOptDir = error(_)
        ),
        module_name_to_file_name(Globals, $pred, do_not_create_dirs,
            ext_other(other_ext(".trans_opt")), Dep, TransOptName, !IO),
        search_for_file_returning_dir(IntermodDirs, TransOptName,
            MaybeTransOptDir, !IO),
        (
            MaybeTransOptDir = ok(_),
            !:TransOptDeps = [Dep | !.TransOptDeps]
        ;
            MaybeTransOptDir = error(_)
        )
    ;
        Found = yes
    ).

get_opt_deps(_Globals, _BuildOptFiles, _IntermodDirs, _OtherExt, [], [], !IO).
get_opt_deps(Globals, BuildOptFiles, IntermodDirs, OtherExt, [Dep | Deps],
        !:OptDeps, !IO) :-
    get_opt_deps(Globals, BuildOptFiles, IntermodDirs, OtherExt, Deps,
        !:OptDeps, !IO),
    (
        BuildOptFiles = yes,
        search_for_module_source(IntermodDirs, Dep, Result1, !IO),
        (
            Result1 = ok(_),
            !:OptDeps = [Dep | !.OptDeps],
            Found = yes
        ;
            Result1 = error(_),
            Found = no
        )
    ;
        BuildOptFiles = no,
        Found = no
    ),
    (
        Found = no,
        module_name_to_search_file_name(Globals, $pred,
            ext_other(OtherExt), Dep, OptName, !IO),
        search_for_file(IntermodDirs, OptName, MaybeOptDir, !IO),
        (
            MaybeOptDir = ok(_),
            !:OptDeps = [Dep | !.OptDeps]
        ;
            MaybeOptDir = error(_)
        )
    ;
        Found = yes
    ).

%---------------------------------------------------------------------------%

:- pred compare_module_names(module_name::in, module_name::in,
    comparison_result::out) is det.

compare_module_names(Sym1, Sym2, Result) :-
    Str1 = sym_name_to_string(Sym1),
    Str2 = sym_name_to_string(Sym2),
    compare(Result, Str1, Str2).

%---------------------------------------------------------------------------%
:- end_module parse_tree.write_deps_file.
%---------------------------------------------------------------------------%
