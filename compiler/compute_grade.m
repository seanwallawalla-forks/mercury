%---------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et
%---------------------------------------------------------------------------%
% Copyright (C) 1994-2014 The University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%---------------------------------------------------------------------------%
%
% This module computes the grade from the values of the options.
%
%---------------------------------------------------------------------------%

:- module libs.compute_grade.
:- interface.

:- import_module libs.globals.
:- import_module libs.options.
:- import_module parse_tree.
:- import_module parse_tree.error_util.

:- import_module list.

%---------------------------------------------------------------------------%

    % This predicate generates error messages for various combinations of
    % grade components (or their equivalent command line options) that are
    % incompatible with each other.
    %
    % NOTE this predicate does not check *all* combinations, some of the checks
    % are carried out by the predicate convert_options_to_globals, while others
    % are carried out by the code that decomposes the grade string.
    %
    % NOTE: since grade components may be specified by either a grade component
    % or via a command line option, please try to ensure that the error
    % messages generated by this predicate cover both situations.
    %
    % XXX we don't currently handle the .par, .threadscope or any undocumented
    % grade components here.
    %
:- pred check_grade_component_compatibility(globals::in,
    compilation_target::in, gc_method::in,
    list(error_spec)::in, list(error_spec)::out) is det.

    % Apply some sanity checks to the library grade set and then apply any
    % library grade filters to that set.
    %
    % XXX we could do better with the sanity checks, currently we only
    % check that all the grade components are valid and that there are
    % no duplicate grade components.
    %
:- pred postprocess_options_libgrades(globals::in, globals::out,
    list(error_spec)::in, list(error_spec)::out) is det.

    % The inverse of compute_grade: given a grade, set the appropriate options.
    %
:- pred convert_grade_option(string::in, option_table::in, option_table::out)
    is semidet.

    % Produce the grade component of grade-specific installation directories.
    %
:- pred grade_directory_component(globals::in, string::out) is det.

%---------------------------------------------------------------------------%

    % Given the current set of options, figure out which grade to use.
    %
:- pred compute_grade(globals::in, string::out) is det.

%---------------------------------------------------------------------------%
%---------------------------------------------------------------------------%

:- implementation.

:- import_module libs.compiler_util.

:- import_module bool.
:- import_module char.
:- import_module getopt.
:- import_module int.
:- import_module map.
:- import_module maybe.
:- import_module pair.
:- import_module set.
:- import_module solutions.
:- import_module string.

%---------------------------------------------------------------------------%

check_grade_component_compatibility(Globals, Target, GC_Method, !Specs) :-
    TargetStr = compilation_target_string(Target),

    % Check that the GC method is compatible with the target language.
    %
    (
        Target = target_c
        % XXX how are we supposed to handle gc_automatic for C?
    ;
        ( Target = target_csharp
        ; Target = target_java
        ),
        (
            % At this point, both of these values are acceptable for the
            % non-C targets.
            ( GC_Method = gc_automatic
            ; GC_Method = gc_none
            )
        ;
            ( GC_Method = gc_boehm
            ; GC_Method = gc_boehm_debug
            ),
            BoehmSpec =
                [words("Use of Boehm GC is incompatible with"),
                words("target language"), words(TargetStr), suffix("."), nl],
            add_error(phase_options, BoehmSpec, !Specs)
        ;
            GC_Method = gc_hgc,
            HGCSpec =
                [words("Use of HGC is incompatible with"),
                words("target language"), words(TargetStr), suffix("."), nl],
            add_error(phase_options, HGCSpec, !Specs)
        ;
            GC_Method = gc_accurate,
            AGCSpec =
                [words("Use of accurate GC is incompatible with"),
                words("target language"), words(TargetStr), suffix("."), nl],
            add_error(phase_options, AGCSpec, !Specs)
        )
    ),

    % Time profiling is only supported by the C back-ends.
    %
    globals.lookup_bool_option(Globals, profile_time, ProfileTime),
    (
        ProfileTime = yes,
        (
            ( Target = target_java
            ; Target = target_csharp
            ),
            TimeProfpec =
                [words("Time profiling is incompatible with"),
                words("target language"), words(TargetStr), suffix("."), nl],
            add_error(phase_options, TimeProfpec, !Specs)
        ;
            Target = target_c
        )
    ;
        ProfileTime = no
    ),

    % Memory profiling is only supported by the C back-ends.
    %
    globals.lookup_bool_option(Globals, profile_memory, ProfileMemory),
    (
        ProfileMemory = yes,
        (
            ( Target = target_java
            ; Target = target_csharp
            ),
            MemProfpec =
                [words("Memory profiling is incompatible with"),
                words("target language"), words(TargetStr), suffix("."), nl],
            add_error(phase_options, MemProfpec, !Specs)
        ;
            Target = target_c
        )
    ;
        ProfileMemory = no
    ),

    % Compatibility with profile_deep is checked by
    % handle_profiling_options in handle_options.m.

    % Compatibility with debugging is checked by
    % handle_debugging_options in handle_options.m.

    % Trailing is only supported by the C back-ends.
    %
    globals.lookup_bool_option(Globals, use_trail,  UseTrail),
    globals.lookup_bool_option(Globals, trail_segments, TrailSegments),
    ( if
        % NOTE: We haven't yet implicitly enabled use_trail segments
        % if trail_segments are enabled, so we must check both here.
        ( UseTrail = yes
        ; TrailSegments = yes
        )
    then
        (
            ( Target = target_java
            ; Target = target_csharp
            ),
            TrailSpec =
                [words("Trailing is incompatible with"),
                words("target language"), words(TargetStr), suffix("."), nl],
            add_error(phase_options, TrailSpec, !Specs)
        ;
            Target = target_c
        )
    else
        true
    ),

    % Stack segments are only supported by the low level C back-end.
    %
    globals.lookup_bool_option(Globals, stack_segments, StackSegments),
    (
        StackSegments = yes,
        (
            Target = target_c,
            globals.lookup_bool_option(Globals, highlevel_code, HighLevelCode),
            (
                HighLevelCode = yes,
                StackSegmentpec =
                    [words("Stack segments are incompatible with"),
                    words("the high-level C backend."), nl],
                add_error(phase_options, StackSegmentpec, !Specs)
            ;
                HighLevelCode = no
            )
        ;
            ( Target = target_java
            ; Target = target_csharp
            ),
            StackSegmentpec =
                [words("Stack segments are incompatible with"),
                words("target language"), words(TargetStr), suffix("."), nl],
            add_error(phase_options, StackSegmentpec, !Specs)
        )
    ;
        StackSegments = no
    ),

    % Single precision floats are only compatible with the C back-ends.
    % (At least for Mercury, that's currently the case.)
    globals.lookup_bool_option(Globals, single_prec_float, SinglePrecFloat),
    (
        SinglePrecFloat = yes,
        (
            ( Target = target_java
            ; Target = target_csharp
            ),
            SPFSpec =
                [words("Single precision floats are incompatible with"),
                words("target language"), words(TargetStr), suffix("."), nl],
            add_error(phase_options, SPFSpec, !Specs)
        ;
            Target = target_c
        )
    ;
        SinglePrecFloat = no
    ).

%---------------------------------------------------------------------------%

postprocess_options_libgrades(!Globals, !Specs) :-
    globals.lookup_accumulating_option(!.Globals, libgrades_include_components,
        IncludeComponentStrs),
    globals.lookup_accumulating_option(!.Globals, libgrades_exclude_components,
        OmitComponentStrs),
    list.foldl2(string_to_grade_component("included"),
        IncludeComponentStrs, [], IncludeComponents, !Specs),
    list.foldl2(string_to_grade_component("excluded"),
        OmitComponentStrs, [], OmitComponents, !Specs),
    some [!LibGrades] (
        globals.lookup_accumulating_option(!.Globals, libgrades, !:LibGrades),
        % NOTE: the two calls to foldl2 here will preserve the original
        % relative ordering of the library grades.
        list.foldl2(filter_grade(must_contain, IncludeComponents),
            !.LibGrades, [], !:LibGrades, !Specs),
        list.foldl2(filter_grade(must_not_contain, OmitComponents),
            !.LibGrades, [], !:LibGrades, !Specs),
        globals.set_option(libgrades, accumulating(!.LibGrades), !Globals)
    ).

    % string_to_grade_component(OptionStr, Comp, !Comps, !Specs):
    %
    % If `Comp' is a string that represents a valid grade component
    % then add it to !Comps. If it is not then emit an error message.
    % `OptionStr' should be the name of the command line option for
    % which the error is to be reported.
    %
:- pred string_to_grade_component(string::in, string::in,
    list(string)::in, list(string)::out,
    list(error_spec)::in, list(error_spec)::out) is det.

string_to_grade_component(FilterDesc, Comp, !Comps, !Specs) :-
    ( if grade_component_table(Comp, _, _, _, _) then
        !:Comps = [Comp | !.Comps]
    else if Comp = "erlang" then
        Pieces = [words("Support for"), quote("erlang"), words("as an"),
            words(FilterDesc), words("library grade component"),
            words("has been discontinued"), nl],
        Spec = simplest_no_context_spec($pred, severity_informational,
            phase_options, Pieces),
        !:Specs = [Spec | !.Specs]
    else
        Pieces = [words("Unknown"), words(FilterDesc),
            words("library grade component:"), quote(Comp), suffix("."), nl],
        add_error(phase_options, Pieces, !Specs)
    ).

    % filter_grade(FilterPred, Components, GradeString, !Grades, !Specs):
    %
    % Convert `GradeString' into a list of grade component strings, and
    % then check whether the given grade should be filtered from the
    % library grade set by applying the closure `FilterPred(Components)',
    % to that list. The grade is removed from the library grade set if
    % that application fails.
    %
    % Emits an error if `GradeString' cannot be converted into a list
    % of grade component strings.
    %
:- pred filter_grade(pred(list(string), list(string))
    ::in(pred(in, in) is semidet), list(string)::in,
    string::in, list(string)::in, list(string)::out,
    list(error_spec)::in, list(error_spec)::out) is det.

filter_grade(FilterPred, CondComponents, GradeString, !Grades, !Specs) :-
    grade_string_to_comp_strings(GradeString, MaybeGrade, !Specs),
    (
        MaybeGrade = yes(GradeComponents),
        ( if FilterPred(CondComponents, GradeComponents) then
            !:Grades = [GradeString | !.Grades]
        else
            true
        )
    ;
        MaybeGrade = no
    ).

:- pred must_contain(list(string)::in, list(string)::in) is semidet.

must_contain(IncludeComponents, GradeComponents) :-
    all [Component] (
        list.member(Component, IncludeComponents)
    =>
        list.member(Component, GradeComponents)
    ).

:- pred must_not_contain(list(string)::in, list(string)::in) is semidet.

must_not_contain(OmitComponents, GradeComponents) :-
    all [Component] (
        list.member(Component, OmitComponents)
    =>
        not list.member(Component, GradeComponents)
    ).

    % Convert a grade string into a list of component strings.
    % Emit an invalid grade error if the conversion fails.
    %
:- pred grade_string_to_comp_strings(string::in, maybe(list(string))::out,
    list(error_spec)::in, list(error_spec)::out) is det.

grade_string_to_comp_strings(GradeString, MaybeGrade, !Specs) :-
    ( if
        split_grade_string(GradeString, ComponentStrs),
        StrToComp = ( pred(Str::in, Str::out) is semidet :-
            grade_component_table(Str, _, _, _, _)
        ),
        list.map(StrToComp, ComponentStrs, Components0)
    then
        list.sort_and_remove_dups(Components0, Components),
        ( if list.length(Components0) > list.length(Components) then
            GradeSpec =
                [words("Invalid library grade:"), quote(GradeString), nl],
            add_error(phase_options, GradeSpec, !Specs),
            MaybeGrade = no
        else
            MaybeGrade = yes(Components)
        )
    else
        GradeSpec =
            [words("Invalid library grade:"), quote(GradeString), nl],
        add_error(phase_options, GradeSpec, !Specs),
        MaybeGrade = no
    ).

%---------------------------------------------------------------------------%

    % IMPORTANT: any changes here may require similar changes to other files,
    % see the list of files at the top of runtime/mercury_grade.h
    %
    % The grade_component type should have one constructor for each
    % dimension of the grade. It is used when converting the components
    % of the grade string to make sure the grade string doesn't contain
    % more than one value for each dimension (eg *.gc.agc).
    % Adding a value here will require adding clauses to the
    % grade_component_table.
    %
    % A --grade option causes all the grade dependent options to be
    % reset, and only those described by the grade string to be set.
    % The value to which a grade option should be reset should be given
    % in the grade_start_values table below.
    %
    % The ordering of the components here is the same as the order used in
    % scripts/canonical_grand.sh-subr, and any change here will require a
    % corresponding change there. The only place where the ordering actually
    % matters is for constructing the pathname for the grade of the library,
    % etc for linking (and installation).
    %
:- type grade_component
    --->    comp_gcc_ext        % gcc extensions etc. -- see
                                % grade_component_table
    ;       comp_par            % parallelism / multithreading
    ;       comp_par_threadscope
                                % Whether to support theadscope profiling of
                                % parallel grades.
    ;       comp_gc             % the kind of GC to use
    ;       comp_prof           % what profiling options to use
    ;       comp_term_size      % whether or not to record term sizes
    ;       comp_trail          % whether or not to use trailing
    ;       comp_minimal_model  % whether we set up for minimal model tabling
    ;       comp_pregen_spf     % whether to assume settings for the
                                % pregenerated C source distribution;
                                % and whether or not to use single precision
                                % floating point values.
    ;       comp_lowlevel       % what to do to target code
    ;       comp_trace          % tracing/debugging options
    ;       comp_stack_extend   % automatic stack extension
    ;       comp_regions.       % Whether or not to use region-based memory
                                % management.

convert_grade_option(GradeString, Options0, Options) :-
    reset_grade_options(Options0, Options1),
    split_grade_string(GradeString, Components),
    set.init(NoComps),
    list.foldl2(
        ( pred(CompStr::in, Opts0::in, Opts::out,
                CompSet0::in, CompSet::out) is semidet :-
            grade_component_table(CompStr, Comp, CompOpts, MaybeTargets, _),

            % Check that the component isn't mentioned more than once.
            not set.member(Comp, CompSet0),
            set.insert(Comp, CompSet0, CompSet),
            add_option_list(CompOpts, Opts0, Opts1),

            % XXX Here the behaviour matches what used to happen and that is
            % to only set the target option iff there was only one possible
            % target. Is this a bug?
            ( if MaybeTargets = yes([Target]) then
                add_option_list([target - Target], Opts1, Opts)
            else
                Opts = Opts1
            )
        ), Components, Options1, Options, NoComps, _FinalComps).

:- pred add_option_list(list(pair(option, option_data))::in, option_table::in,
    option_table::out) is det.

add_option_list(CompOpts, Opts0, Opts) :-
    list.foldl(
        ( pred(Opt::in, Opts1::in, Opts2::out) is det :-
            Opt = Option - Data,
            map.set(Option, Data, Opts1, Opts2)
        ), CompOpts, Opts0, Opts).

grade_directory_component(Globals, Grade) :-
    compute_grade(Globals, Grade).
    % We used to strip out the `.picreg' part of the grade,
    % while we still had it.

compute_grade(Globals, Grade) :-
    globals.get_options(Globals, Options),
    compute_grade_components(Options, Components),
    (
        Components = [],
        Grade = "none"
    ;
        Components = [_ | _],
        construct_string(Components, Grade)
    ).

:- pred construct_string(list(pair(grade_component, string))::in, string::out)
    is det.

construct_string([], "").
construct_string([_ - Bit | Bits], Grade) :-
    (
        Bits = [_ | _],
        construct_string(Bits, Grade0),
        string.append_list([Bit, ".", Grade0], Grade)
    ;
        Bits = [],
        Grade = Bit
    ).

:- pred compute_grade_components(option_table::in,
    list(pair(grade_component, string))::out) is det.

compute_grade_components(Options, GradeComponents) :-
    solutions(
        ( pred(CompData::out) is nondet :-
            grade_component_table(Name, Comp, CompOpts, MaybeTargets,
                IncludeInGradeString),

            % For a possible component of the grade string, include it in the
            % actual grade string if all the option settings that it implies
            % are true.
            all [Opt, Value] (
                list.member(Opt - Value, CompOpts)
            =>
                map.search(Options, Opt, Value)
            ),

            % Don't include `.mm' or `.dmm' in grade strings because they are
            % just synonyms for `.mmsc' and `.dmmsc' respectively.
            IncludeInGradeString = yes,

            % When checking gcc_ext there exist grades which can have
            % more than one possible target, ensure that the target
            % in the options table matches one of the possible targets.
            (
                MaybeTargets = yes(Targets),
                list.member(Target, Targets),
                map.search(Options, target, Target)
            ;
                MaybeTargets = no
            ),
            CompData = Comp - Name
        ), GradeComponents).

    % grade_component_table(ComponetStr, Component, Options, MaybeTargets,
    %   IncludeGradeStr):
    %
    % `IncludeGradeStr' is `yes' if the component should be included
    % in the grade string. It is `no' for those components that are
    % just synonyms for other comments, as .mm is for .mmsc.
    %
:- pred grade_component_table(string, grade_component,
    list(pair(option, option_data)), maybe(list(option_data)), bool).
:- mode grade_component_table(in, out, out, out, out) is semidet.
:- mode grade_component_table(out, in, out, out, out) is multi.
:- mode grade_component_table(out, out, out, out, out) is multi.

    % Base components.
    % These specify the basic compilation model we use,
    % including the choice of back-end and the use of gcc extensions.
grade_component_table("none", comp_gcc_ext, [
        asm_labels              - bool(no),
        gcc_non_local_gotos     - bool(no),
        gcc_global_registers    - bool(no),
        highlevel_code          - bool(no) ],
        yes([string("c")]), yes).
grade_component_table("reg", comp_gcc_ext, [
        asm_labels              - bool(no),
        gcc_non_local_gotos     - bool(no),
        gcc_global_registers    - bool(yes),
        highlevel_code          - bool(no)],
        yes([string("c")]), yes).
grade_component_table("jump", comp_gcc_ext, [
        asm_labels              - bool(no),
        gcc_non_local_gotos     - bool(yes),
        gcc_global_registers    - bool(no),
        highlevel_code          - bool(no)],
        yes([string("c")]), yes).
grade_component_table("asm_jump", comp_gcc_ext, [
        asm_labels              - bool(yes),
        gcc_non_local_gotos     - bool(yes),
        gcc_global_registers    - bool(no),
        highlevel_code          - bool(no)],
        yes([string("c")]), yes).
grade_component_table("fast", comp_gcc_ext, [
        asm_labels              - bool(no),
        gcc_non_local_gotos     - bool(yes),
        gcc_global_registers    - bool(yes),
        highlevel_code          - bool(no)],
        yes([string("c")]), yes).
grade_component_table("asm_fast", comp_gcc_ext, [
        asm_labels              - bool(yes),
        gcc_non_local_gotos     - bool(yes),
        gcc_global_registers    - bool(yes),
        highlevel_code          - bool(no)],
        yes([string("c")]), yes).
grade_component_table("hlc", comp_gcc_ext, [
        asm_labels              - bool(no),
        gcc_non_local_gotos     - bool(no),
        gcc_global_registers    - bool(no),
        highlevel_code          - bool(yes)],
        yes([string("c")]), yes).
grade_component_table("java", comp_gcc_ext, [
        asm_labels              - bool(no),
        gcc_non_local_gotos     - bool(no),
        gcc_global_registers    - bool(no),
        highlevel_code          - bool(yes)],
        yes([string("java")]), yes).
grade_component_table("csharp", comp_gcc_ext, [
        asm_labels              - bool(no),
        gcc_non_local_gotos     - bool(no),
        gcc_global_registers    - bool(no),
        highlevel_code          - bool(yes)],
        yes([string("csharp")]), yes).

    % Parallelism/multithreading components.
grade_component_table("par", comp_par, [parallel - bool(yes)], no, yes).

    % Threadscope profiling in parallel grades.
grade_component_table("threadscope", comp_par_threadscope,
    [threadscope - bool(yes)], no, yes).

    % GC components.
grade_component_table("gc", comp_gc, [gc - string("boehm")], no, yes).
grade_component_table("gcd", comp_gc, [gc - string("boehm_debug")], no, yes).
grade_component_table("hgc", comp_gc, [gc - string("hgc")], no, yes).
grade_component_table("agc", comp_gc, [gc - string("accurate")], no, yes).

    % Profiling components.
grade_component_table("prof", comp_prof,
    [profile_time - bool(yes), profile_calls - bool(yes),
    profile_memory - bool(no), profile_deep - bool(no)], no, yes).
grade_component_table("proftime", comp_prof,
    [profile_time - bool(yes), profile_calls - bool(no),
    profile_memory - bool(no), profile_deep - bool(no)], no, yes).
grade_component_table("profcalls", comp_prof,
    [profile_time - bool(no), profile_calls - bool(yes),
    profile_memory - bool(no), profile_deep - bool(no)], no, yes).
grade_component_table("memprof", comp_prof,
    [profile_time - bool(no), profile_calls - bool(yes),
    profile_memory - bool(yes), profile_deep - bool(no)], no, yes).
grade_component_table("profall", comp_prof,
    [profile_time - bool(yes), profile_calls - bool(yes),
    profile_memory - bool(yes), profile_deep - bool(no)], no, yes).
grade_component_table("profdeep", comp_prof,
    [profile_time - bool(no), profile_calls - bool(no),
    profile_memory - bool(no), profile_deep - bool(yes)], no, yes).

    % Term size components.
grade_component_table("tsw", comp_term_size,
    [record_term_sizes_as_words - bool(yes),
    record_term_sizes_as_cells - bool(no)], no, yes).
grade_component_table("tsc", comp_term_size,
    [record_term_sizes_as_words - bool(no),
    record_term_sizes_as_cells - bool(yes)], no, yes).

    % Trailing components.
grade_component_table("tr", comp_trail,
    [use_trail - bool(yes), trail_segments - bool(yes)], no, yes).
    % NOTE: we do no include `.trseg' in grades strings because it
    % it is just a synonym for `.tr'.
grade_component_table("trseg", comp_trail,
    [use_trail - bool(yes), trail_segments - bool(yes)], no, no).

    % Minimal model tabling components.
    % NOTE: we do not include `.mm' and `.dmm' in grade strings
    % because they are just synonyms for `.mmsc' and `.dmmsc'.
grade_component_table("mm", comp_minimal_model,
    [use_minimal_model_stack_copy - bool(yes),
    use_minimal_model_own_stacks - bool(no),
    minimal_model_debug - bool(no)], no, no).
grade_component_table("dmm", comp_minimal_model,
    [use_minimal_model_stack_copy - bool(yes),
    use_minimal_model_own_stacks - bool(no),
    minimal_model_debug - bool(yes)], no, no).
grade_component_table("mmsc", comp_minimal_model,
    [use_minimal_model_stack_copy - bool(yes),
    use_minimal_model_own_stacks - bool(no),
    minimal_model_debug - bool(no)], no, yes).
grade_component_table("dmmsc", comp_minimal_model,
    [use_minimal_model_stack_copy - bool(yes),
    use_minimal_model_own_stacks - bool(no),
    minimal_model_debug - bool(yes)], no, yes).
grade_component_table("mmos", comp_minimal_model,
    [use_minimal_model_stack_copy - bool(no),
    use_minimal_model_own_stacks - bool(yes),
    minimal_model_debug - bool(no)], no, yes).
grade_component_table("dmmos", comp_minimal_model,
    [use_minimal_model_stack_copy - bool(no),
    use_minimal_model_own_stacks - bool(yes),
    minimal_model_debug - bool(yes)], no, yes).

    % Settings for pre-generated source distribution
    % or single-precision floats.
grade_component_table("pregen", comp_pregen_spf,
    [pregenerated_dist - bool(yes)], no, yes).
grade_component_table("spf", comp_pregen_spf,
    [single_prec_float - bool(yes),
    unboxed_float - bool(yes)], no, yes).

    % Debugging/Tracing components.
grade_component_table("decldebug", comp_trace,
    [exec_trace - bool(yes), decl_debug - bool(yes)], no, yes).
grade_component_table("debug", comp_trace,
    [exec_trace - bool(yes), decl_debug - bool(no)], no, yes).
grade_component_table("ssdebug", comp_trace,
    [source_to_source_debug - bool(yes)], no, yes).

    % Low (target) level debugging components.
grade_component_table("ll_debug", comp_lowlevel,
    [low_level_debug - bool(yes), target_debug - bool(yes)], no, yes).

    % Stack extension components.
grade_component_table("exts", comp_stack_extend,
    [extend_stacks_when_needed - bool(yes), stack_segments - bool(no)],
    no, yes).
grade_component_table("stseg", comp_stack_extend,
    [extend_stacks_when_needed - bool(no), stack_segments - bool(yes)],
    no, yes).

    % Region-based memory managment components
grade_component_table("rbmm", comp_regions,
    [use_regions - bool(yes),
    use_regions_debug - bool(no), use_regions_profiling - bool(no)],
    no, yes).
grade_component_table("rbmmd", comp_regions,
    [use_regions - bool(yes),
    use_regions_debug - bool(yes), use_regions_profiling - bool(no)],
    no, yes).
grade_component_table("rbmmp", comp_regions,
    [use_regions - bool(yes),
    use_regions_debug - bool(no), use_regions_profiling - bool(yes)],
    no, yes).
grade_component_table("rbmmdp", comp_regions,
    [use_regions - bool(yes),
    use_regions_debug - bool(yes), use_regions_profiling - bool(yes)],
    no, yes).

:- pred reset_grade_options(option_table::in, option_table::out) is det.

reset_grade_options(Options0, Options) :-
    solutions.aggregate(grade_start_values,
        ( pred(Pair::in, Opts0::in, Opts::out) is det :-
            Pair = Option - Value,
            map.set(Option, Value, Opts0, Opts)
        ), Options0, Options).

:- pred grade_start_values(pair(option, option_data)::out) is multi.

grade_start_values(asm_labels - bool(no)).
grade_start_values(gcc_non_local_gotos - bool(no)).
grade_start_values(gcc_global_registers - bool(no)).
grade_start_values(highlevel_code - bool(no)).
grade_start_values(parallel - bool(no)).
grade_start_values(threadscope - bool(no)).
grade_start_values(gc - string("none")).
grade_start_values(profile_deep - bool(no)).
grade_start_values(profile_time - bool(no)).
grade_start_values(profile_calls - bool(no)).
grade_start_values(profile_memory - bool(no)).
grade_start_values(use_trail - bool(no)).
grade_start_values(trail_segments - bool(no)).
grade_start_values(use_minimal_model_stack_copy - bool(no)).
grade_start_values(use_minimal_model_own_stacks - bool(no)).
grade_start_values(minimal_model_debug - bool(no)).
grade_start_values(pregenerated_dist - bool(no)).
grade_start_values(single_prec_float - bool(no)).
grade_start_values(exec_trace - bool(no)).
grade_start_values(decl_debug - bool(no)).
grade_start_values(source_to_source_debug - bool(no)).
grade_start_values(extend_stacks_when_needed - bool(no)).
grade_start_values(stack_segments - bool(no)).
grade_start_values(use_regions - bool(no)).
grade_start_values(use_regions_debug - bool(no)).
grade_start_values(use_regions_profiling - bool(no)).
grade_start_values(low_level_debug - bool(no)).

:- pred split_grade_string(string::in, list(string)::out) is semidet.

split_grade_string(GradeStr, Components) :-
    string.to_char_list(GradeStr, Chars),
    split_grade_string_2(Chars, Components).

:- pred split_grade_string_2(list(char)::in, list(string)::out) is semidet.

split_grade_string_2([], []).
split_grade_string_2(Chars, Components) :-
    Chars = [_ | _],
    list.take_while(char_is_not('.'), Chars, ThisChars, RestChars0),
    string.from_char_list(ThisChars, ThisComponent),
    Components = [ThisComponent | RestComponents],
    (
        RestChars0 = [_ | RestChars],                       % Discard the `.'.
        split_grade_string_2(RestChars, RestComponents)
    ;
        RestChars0 = [],
        RestComponents = []
    ).

:- pred char_is_not(char::in, char::in) is semidet.

char_is_not(A, B) :-
    A \= B.

%---------------------------------------------------------------------------%
:- end_module libs.compute_grade.
%---------------------------------------------------------------------------%
