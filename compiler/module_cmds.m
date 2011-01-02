%-----------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et
%-----------------------------------------------------------------------------%
% Copyright (C) 2008-2011 The University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%-----------------------------------------------------------------------------%
%
% File: module_cmds.m.
%
% This module handles the most of the commands generated by the
% parse_tree package.
%
%-----------------------------------------------------------------------------%

:- module parse_tree.module_cmds.
:- interface.

:- import_module mdbcomp.prim_data.
:- import_module libs.file_util.
:- import_module libs.globals.

:- import_module bool.
:- import_module list.
:- import_module io.
:- import_module maybe.

%-----------------------------------------------------------------------------%

:- type update_interface_result
    --->    interface_new_or_changed
    ;       interface_unchanged
    ;       interface_error.

    % update_interface_return_changed(Globals, FileName, Result):
    %
    % Update the interface file FileName from FileName.tmp if it has changed.
    %
:- pred update_interface_return_changed(globals::in, file_name::in,
    update_interface_result::out, io::di, io::uo) is det.

:- pred update_interface_return_succeeded(globals::in, file_name::in,
    bool::out, io::di, io::uo) is det.

:- pred update_interface(globals::in, file_name::in, io::di, io::uo) is det.

%-----------------------------------------------------------------------------%

    % copy_file(Globals, Source, Destination, Succeeded, !IO).
    %
    % XXX A version of this predicate belongs in the standard library.
    %
:- pred copy_file(globals::in, file_name::in, file_name::in, io.res::out,
    io::di, io::uo) is det.

    % maybe_make_symlink(Globals, TargetFile, LinkName, Result, !IO):
    %
    % If `--use-symlinks' is set, attempt to make LinkName a symlink
    % pointing to LinkTarget.
    %
:- pred maybe_make_symlink(globals::in, file_name::in, file_name::in,
    bool::out, io::di, io::uo) is det.

    % make_symlink_or_copy_file(Globals, LinkTarget, LinkName, Succeeded, !IO):
    %
    % Attempt to make LinkName a symlink pointing to LinkTarget, copying
    % LinkTarget to LinkName if that fails (or if `--use-symlinks' is not set).
    %
:- pred make_symlink_or_copy_file(globals::in, file_name::in, file_name::in,
    bool::out, io::di, io::uo) is det.

%-----------------------------------------------------------------------------%

    % touch_interface_datestamp(Globals, ModuleName, Ext, !IO):
    %
    % Touch the datestamp file `ModuleName.Ext'. Datestamp files are used
    % to record when each of the interface files was last updated.
    %
:- pred touch_interface_datestamp(globals::in, module_name::in, string::in,
    io::di, io::uo) is det.

    % touch_datestamp(Globals, FileName, !IO):
    %
    % Update the modification time for the given file,
    % clobbering the contents of the file.
    %
:- pred touch_datestamp(globals::in, file_name::in, io::di, io::uo) is det.

%-----------------------------------------------------------------------------%

    % If the bool is `no', set the exit status to 1.
    %
:- pred maybe_set_exit_status(bool::in, io::di, io::uo) is det.

%-----------------------------------------------------------------------------%

:- type quote_char
    --->    forward     % '
    ;       double.     % "

:- type command_verbosity
    --->    cmd_verbose
            % Output the command line only with `--verbose'.

    ;       cmd_verbose_commands.
            % Output the command line with `--verbose-commands'. This should be
            % used for commands that may be of interest to the user.

    % invoke_system_command(Globals, ErrorStream, Verbosity, Command, Succeeded)
    %
    % Invoke an executable. Both standard and error output will go to the
    % specified output stream.
    %
:- pred invoke_system_command(globals::in, io.output_stream::in,
    command_verbosity::in, string::in, bool::out, io::di, io::uo) is det.

    % invoke_system_command_maybe_filter_output(Globals, ErrorStream,
    %   Verbosity, Command, MaybeProcessOutput, Succeeded)
    %
    % Invoke an executable. Both standard and error output will go to the
    % specified output stream after being piped through `ProcessOutput'
    % if MaybeProcessOutput is yes(ProcessOutput).
    %
:- pred invoke_system_command_maybe_filter_output(globals::in,
    io.output_stream::in, command_verbosity::in, string::in, maybe(string)::in,
    bool::out, io::di, io::uo) is det.

    % Make a command string, which needs to be invoked in a shell environment.
    %
:- pred make_command_string(string::in, quote_char::in, string::out) is det.

%-----------------------------------------------------------------------------%
%
% Java command-line tools utilities.
%

    % Create a shell script with the same name as the given module to invoke
    % Java with the appropriate options on the class of the same name.
    %
:- pred create_java_shell_script(globals::in, module_name::in, bool::out,
    io::di, io::uo) is det.

    % Return the standard Mercury libraries needed for a Java program.
    % Return the empty list if --mercury-standard-library-directory
    % is not set.
    %
:- pred get_mercury_std_libs_for_java(globals::in, list(string)::out) is det.

    % Given a list .class files, return the list of .class files that should be
    % passed to `jar'.  This is required because nested classes are in separate
    % files which we don't know about, so we have to scan the directory to
    % figure out which files were produced by `javac'.
    %
:- pred list_class_files_for_jar(globals::in, list(string)::in, string::out,
    list(string)::out, io::di, io::uo) is det.

    % Given a `mmake' variable reference to a list of .class files, return an
    % expression that generates the list of arguments for `jar' to reference
    % those class files.
    %
:- pred list_class_files_for_jar_mmake(globals::in, string::in, string::out)
    is det.

    % Get the value of the Java class path from the environment. (Normally
    % it will be obtained from the CLASSPATH environment variable, but if
    % that isn't present then the java.class.path variable may be used instead.
    % This is used for the Java back-end, which doesn't support environment
    % variables properly.)
    %
:- pred get_env_classpath(string::out, io::di, io::uo) is det.

%-----------------------------------------------------------------------------%
%
% Erlang utilities.
%

    % Create a shell script with the same name as the given module to invoke
    % the Erlang runtime system and execute the main/2 predicate in that
    % module.
    %
:- pred create_erlang_shell_script(globals::in, module_name::in, bool::out,
    io::di, io::uo) is det.

%-----------------------------------------------------------------------------%

:- pred create_launcher_shell_script(globals::in, module_name::in,
    pred(io.output_stream, io, io)::in(pred(in, di, uo) is det),
    bool::out, io::di, io::uo) is det.

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- implementation.

:- import_module libs.process_util.
:- import_module libs.handle_options.   % for grade_directory_component
:- import_module libs.options.
:- import_module parse_tree.error_util.
:- import_module parse_tree.file_names.
:- import_module parse_tree.java_names.

:- import_module dir.
:- import_module getopt_io.
:- import_module int.
:- import_module require.
:- import_module set.
:- import_module string.

%-----------------------------------------------------------------------------%

update_interface(Globals, OutputFileName, !IO) :-
    update_interface_return_succeeded(Globals, OutputFileName, Succeeded, !IO),
    (
        Succeeded = no,
        report_error("problem updating interface files.", !IO)
    ;
        Succeeded = yes
    ).

update_interface_return_succeeded(Globals, OutputFileName, Succeeded, !IO) :-
    update_interface_return_changed(Globals, OutputFileName, Result, !IO),
    (
        ( Result = interface_new_or_changed
        ; Result = interface_unchanged
        ),
        Succeeded = yes
    ;
        Result = interface_error,
        Succeeded = no
    ).

update_interface_return_changed(Globals, OutputFileName, Result, !IO) :-
    globals.lookup_bool_option(Globals, verbose, Verbose),
    maybe_write_string(Verbose, "% Updating interface:\n", !IO),
    TmpOutputFileName = OutputFileName ++ ".tmp",
    io.open_binary_input(OutputFileName, OutputFileRes, !IO),
    (
        OutputFileRes = ok(OutputFileStream),
        io.open_binary_input(TmpOutputFileName, TmpOutputFileRes, !IO),
        (
            TmpOutputFileRes = ok(TmpOutputFileStream),
            binary_input_stream_cmp(OutputFileStream, TmpOutputFileStream,
                FilesDiffer, !IO),
            io.close_binary_input(OutputFileStream, !IO),
            io.close_binary_input(TmpOutputFileStream, !IO),
            (
                FilesDiffer = ok(ok(no)),
                Result = interface_unchanged,
                maybe_write_string(Verbose, "% ", !IO),
                maybe_write_string(Verbose, OutputFileName, !IO),
                maybe_write_string(Verbose, "' has not changed.\n", !IO),
                io.remove_file(TmpOutputFileName, _, !IO)
            ;
                FilesDiffer = ok(ok(yes)),
                update_interface_create_file(Globals, "CHANGED",
                    OutputFileName, TmpOutputFileName, Result, !IO)
            ;
                FilesDiffer = ok(error(TmpFileError)),
                Result = interface_error,
                io.write_string("Error reading `", !IO),
                io.write_string(TmpOutputFileName, !IO),
                io.write_string("': ", !IO),
                io.write_string(io.error_message(TmpFileError), !IO),
                io.nl(!IO)
            ;
                FilesDiffer = error(_, _),
                update_interface_create_file(Globals, "been CREATED",
                    OutputFileName, TmpOutputFileName, Result, !IO)
            )
        ;

            TmpOutputFileRes = error(TmpOutputFileError),
            Result = interface_error,
            io.close_binary_input(OutputFileStream, !IO),
            io.write_string("Error creating `", !IO),
            io.write_string(OutputFileName, !IO),
            io.write_string("': ", !IO),
            io.write_string(io.error_message(TmpOutputFileError), !IO),
            io.nl(!IO)
        )
    ;
        OutputFileRes = error(_),
        update_interface_create_file(Globals, "been CREATED",
            OutputFileName, TmpOutputFileName, Result, !IO)
    ).

:- pred update_interface_create_file(globals::in, string::in, string::in,
    string::in, update_interface_result::out, io::di, io::uo) is det.

update_interface_create_file(Globals, Msg, OutputFileName, TmpOutputFileName,
        Result, !IO) :-
    globals.lookup_bool_option(Globals, verbose, Verbose),
    maybe_write_string(Verbose,
        "% `" ++ OutputFileName ++ "' has " ++ Msg ++ ".\n", !IO),
    copy_file(Globals, TmpOutputFileName, OutputFileName, MoveRes, !IO),
    (
        MoveRes = ok,
        Result = interface_new_or_changed
    ;
        MoveRes = error(MoveError),
        Result = interface_error,
        io.write_string("Error creating `" ++ OutputFileName ++ "': " ++
            io.error_message(MoveError), !IO),
        io.nl(!IO)
    ),
    io.remove_file(TmpOutputFileName, _, !IO).

:- pred binary_input_stream_cmp(io.binary_input_stream::in,
    io.binary_input_stream::in, io.maybe_partial_res(io.res(bool))::out,
    io::di, io::uo) is det.

binary_input_stream_cmp(OutputFileStream, TmpOutputFileStream, FilesDiffer,
        !IO) :-
    io.binary_input_stream_foldl2_io_maybe_stop(OutputFileStream,
        binary_input_stream_cmp_2(TmpOutputFileStream),
        ok(no), FilesDiffer0, !IO),

    % Check whether there is anything left in TmpOutputFileStream
    ( FilesDiffer0 = ok(ok(no)) ->
        io.read_byte(TmpOutputFileStream, TmpByteResult2, !IO),
        (
            TmpByteResult2 = ok(_),
            FilesDiffer = ok(ok(yes))
        ;
            TmpByteResult2 = eof,
            FilesDiffer = FilesDiffer0
        ;
            TmpByteResult2 = error(Error),
            FilesDiffer = ok(error(Error))
        )
    ;
        FilesDiffer = FilesDiffer0
    ).

:- pred binary_input_stream_cmp_2(io.binary_input_stream::in, int::in,
    bool::out, io.res(bool)::in, io.res(bool)::out,
    io::di, io::uo) is det.

binary_input_stream_cmp_2(TmpOutputFileStream, Byte, Continue, _, Differ,
        !IO) :-
    io.read_byte(TmpOutputFileStream, TmpByteResult, !IO),
    (
        TmpByteResult = ok(TmpByte),
        ( TmpByte = Byte ->
            Differ = ok(no),
            Continue = yes
        ;
            Differ = ok(yes),
            Continue = no
        )
    ;
        TmpByteResult = eof,
        Differ = ok(yes),
        Continue = no
    ;
        TmpByteResult = error(TmpByteError),
        Differ = error(TmpByteError) : io.res(bool),
        Continue = no
    ).

%-----------------------------------------------------------------------------%

copy_file(Globals, Source, Destination, Res, !IO) :-
    % Try to use the system's cp command in order to preserve metadata.
    globals.lookup_string_option(Globals, install_command, InstallCommand),
    Command = string.join_list("   ", list.map(quote_arg,
        [InstallCommand, Source, Destination])),
    io.output_stream(OutputStream, !IO),
    invoke_system_command(Globals, OutputStream, cmd_verbose, Command,
        Succeeded, !IO),
    (
        Succeeded = yes,
        Res = ok
    ;
        Succeeded = no,
        io.open_binary_input(Source, SourceRes, !IO),
        (
            SourceRes = ok(SourceStream),
            io.open_binary_output(Destination, DestRes, !IO),
            (
                DestRes = ok(DestStream),
                WriteByte = io.write_byte(DestStream),
                io.binary_input_stream_foldl_io(SourceStream, WriteByte, Res,
                    !IO),
                io.close_binary_input(SourceStream, !IO),
                io.close_binary_output(DestStream, !IO)
            ;
                DestRes = error(Error),
                Res = error(Error)
            )
        ;
            SourceRes = error(Error),
            Res = error(Error)
        )
    ).

maybe_make_symlink(Globals, LinkTarget, LinkName, Result, !IO) :-
    globals.lookup_bool_option(Globals, use_symlinks, UseSymLinks),
    (
        UseSymLinks = yes,
        io.remove_file_recursively(LinkName, _, !IO),
        io.make_symlink(LinkTarget, LinkName, LinkResult, !IO),
        Result = ( if LinkResult = ok then yes else no )
    ;
        UseSymLinks = no,
        Result = no
    ).

make_symlink_or_copy_file(Globals, SourceFileName, DestinationFileName,
        Succeeded, !IO) :-
    globals.lookup_bool_option(Globals, use_symlinks, UseSymLinks),
    (
        UseSymLinks = yes,
        LinkOrCopy = "linking",
        io.make_symlink(SourceFileName, DestinationFileName, Result, !IO)
    ;
        UseSymLinks = no,
        LinkOrCopy = "copying",
        copy_file(Globals, SourceFileName, DestinationFileName, Result, !IO)
    ),
    (
        Result = ok,
        Succeeded = yes
    ;
        Result = error(Error),
        Succeeded = no,
        io.progname_base("mercury_compile", ProgName, !IO),
        io.write_string(ProgName, !IO),
        io.write_string(": error ", !IO),
        io.write_string(LinkOrCopy, !IO),
        io.write_string(" `", !IO),
        io.write_string(SourceFileName, !IO),
        io.write_string("' to `", !IO),
        io.write_string(DestinationFileName, !IO),
        io.write_string("': ", !IO),
        io.write_string(io.error_message(Error), !IO),
        io.nl(!IO),
        io.flush_output(!IO)
    ).

%-----------------------------------------------------------------------------%

touch_interface_datestamp(Globals, ModuleName, Ext, !IO) :-
    module_name_to_file_name(Globals, ModuleName, Ext, do_create_dirs,
        OutputFileName, !IO),
    touch_datestamp(Globals, OutputFileName, !IO).

touch_datestamp(Globals, OutputFileName, !IO) :-
    globals.lookup_bool_option(Globals, verbose, Verbose),
    maybe_write_string(Verbose,
        "% Touching `" ++ OutputFileName ++ "'... ", !IO),
    maybe_flush_output(Verbose, !IO),
    io.open_output(OutputFileName, Result, !IO),
    (
        Result = ok(OutputStream),
        io.write_string(OutputStream, "\n", !IO),
        io.close_output(OutputStream, !IO),
        maybe_write_string(Verbose, " done.\n", !IO)
    ;
        Result = error(IOError),
        io.error_message(IOError, IOErrorMessage),
        io.write_string("\nError opening `" ++ OutputFileName
            ++ "' for output: " ++ IOErrorMessage ++ ".\n", !IO)
    ).

%-----------------------------------------------------------------------------%

maybe_set_exit_status(yes, !IO).
maybe_set_exit_status(no, !IO) :-
    io.set_exit_status(1, !IO).

%-----------------------------------------------------------------------------%

invoke_system_command(Globals, ErrorStream, Verbosity,
        Command, Succeeded, !IO) :-
    invoke_system_command_maybe_filter_output(Globals, ErrorStream, Verbosity,
        Command, no, Succeeded, !IO).

invoke_system_command_maybe_filter_output(Globals, ErrorStream, Verbosity,
        Command, MaybeProcessOutput, Succeeded, !IO) :-
    % This predicate shouldn't alter the exit status of mercury_compile.
    io.get_exit_status(OldStatus, !IO),
    globals.lookup_bool_option(Globals, verbose, Verbose),
    (
        Verbosity = cmd_verbose,
        PrintCommand = Verbose
    ;
        Verbosity = cmd_verbose_commands,
        globals.lookup_bool_option(Globals, verbose_commands, PrintCommand)
    ),
    (
        PrintCommand = yes,
        io.write_string("% Invoking system command `", !IO),
        io.write_string(Command, !IO),
        io.write_string("'...\n", !IO),
        io.flush_output(!IO)
    ;
        PrintCommand = no
    ),

    % The output from the command is written to a temporary file,
    % which is then written to the output stream. Without this,
    % the output from the command would go to the current C output
    % and error streams.

    io.make_temp(TmpFile, !IO),
    ( use_dotnet ->
        % XXX can't use Bourne shell syntax to redirect on .NET
        % XXX the output will go to the wrong place!
        CommandRedirected = Command
    ; use_win32 ->
        % On windows we can't in general redirect standard error in the
        % shell.
        CommandRedirected = Command ++ " > " ++ TmpFile
    ;
        CommandRedirected =
            string.append_list([Command, " > ", TmpFile, " 2>&1"])
    ),
    io.call_system_return_signal(CommandRedirected, Result, !IO),
    (
        Result = ok(exited(Status)),
        maybe_write_string(PrintCommand, "% done.\n", !IO),
        ( Status = 0 ->
            CommandSucceeded = yes
        ;
            % The command should have produced output describing the error.
            CommandSucceeded = no
        )
    ;
        Result = ok(signalled(Signal)),
        % Make sure the current process gets the signal. Some systems (e.g.
        % Linux) ignore SIGINT during a call to system().
        raise_signal(Signal, !IO),
        report_error_to_stream(ErrorStream, "system command received signal "
            ++ int_to_string(Signal) ++ ".", !IO),
        CommandSucceeded = no
    ;
        Result = error(Error),
        report_error_to_stream(ErrorStream, io.error_message(Error), !IO),
        CommandSucceeded = no
    ),

    (
        % We can't do bash style redirection on .NET.
        not use_dotnet,
        MaybeProcessOutput = yes(ProcessOutput)
    ->
        io.make_temp(ProcessedTmpFile, !IO),
        
        ( use_win32 ->
            % On windows we can't in general redirect standard
            % error in the shell.
            ProcessOutputRedirected = string.append_list(
                [ProcessOutput, " < ", TmpFile, " > ",
                    ProcessedTmpFile])
        ;
            ProcessOutputRedirected = string.append_list(
                [ProcessOutput, " < ", TmpFile, " > ",
                    ProcessedTmpFile, " 2>&1"])
        ),
        io.call_system_return_signal(ProcessOutputRedirected,
            ProcessOutputResult, !IO),
        io.remove_file(TmpFile, _, !IO),
        (
            ProcessOutputResult = ok(exited(ProcessOutputStatus)),
            maybe_write_string(PrintCommand, "% done.\n", !IO),
            ( ProcessOutputStatus = 0 ->
                ProcessOutputSucceeded = yes
            ;
                % The command should have produced output
                % describing the error.
                ProcessOutputSucceeded = no
            )
        ;
            ProcessOutputResult = ok(signalled(ProcessOutputSignal)),
            % Make sure the current process gets the signal. Some systems
            % (e.g. Linux) ignore SIGINT during a call to system().
            raise_signal(ProcessOutputSignal, !IO),
            report_error_to_stream(ErrorStream,
                "system command received signal "
                ++ int_to_string(ProcessOutputSignal) ++ ".", !IO),
            ProcessOutputSucceeded = no
        ;
            ProcessOutputResult = error(ProcessOutputError),
            report_error_to_stream(ErrorStream,
                io.error_message(ProcessOutputError), !IO),
            ProcessOutputSucceeded = no
        )
    ;
        ProcessOutputSucceeded = yes,
        ProcessedTmpFile = TmpFile
    ),
    Succeeded = CommandSucceeded `and` ProcessOutputSucceeded,

    % Write the output to the error stream.

    io.open_input(ProcessedTmpFile, TmpFileRes, !IO),
    (
        TmpFileRes = ok(TmpFileStream),
        io.input_stream_foldl_io(TmpFileStream, io.write_char(ErrorStream),
            Res, !IO),
        (
            Res = ok
        ;
            Res = error(TmpFileReadError),
            report_error_to_stream(ErrorStream,
                "error reading command output: " ++
                io.error_message(TmpFileReadError), !IO)
        ),
        io.close_input(TmpFileStream, !IO)
    ;
        TmpFileRes = error(TmpFileError),
        report_error_to_stream(ErrorStream,
            "error opening command output: " ++ io.error_message(TmpFileError),
            !IO)
    ),
    io.remove_file(ProcessedTmpFile, _, !IO),
    io.set_exit_status(OldStatus, !IO).

make_command_string(String0, QuoteType, String) :-
    ( use_win32 ->
        (
            QuoteType = forward,
            Quote = " '"
        ;
            QuoteType = double,
            Quote = " """
        ),
        string.append_list(["sh -c ", Quote, String0, Quote], String)
    ;
        String = String0
    ).

%-----------------------------------------------------------------------------%

    % Are we compiling in a .NET environment?
    %
:- pred use_dotnet is semidet.
:- pragma foreign_proc("C#",
    use_dotnet,
    [will_not_call_mercury, promise_pure, thread_safe],
"
    SUCCESS_INDICATOR = true;
").
% The following clause is only used if there is no matching foreign_proc.
use_dotnet :-
    semidet_fail.

    % Are we compiling in a win32 environment?
    %
    % If in doubt, use_win32 should succeed.  This is only used to decide
    % whether to invoke Bourne shell command and shell scripts directly,
    % or whether to invoke them via `sh -c ...'. The latter should work
    % correctly in a Unix environment too, but is a little less efficient
    % since it invokes another process.
    %
:- pred use_win32 is semidet.
:- pragma foreign_proc("C",
    use_win32,
    [will_not_call_mercury, promise_pure, thread_safe],
"
#ifdef MR_WIN32
    SUCCESS_INDICATOR = 1;
#else
    SUCCESS_INDICATOR = 0;
#endif
").
% The following clause is only used if there is no matching foreign_proc.
% See comment above for why it is OK to just succeed here.
use_win32 :-
    semidet_succeed.

%-----------------------------------------------------------------------------%
%
% Java command-line utilities.
%

create_java_shell_script(Globals, MainModuleName, Succeeded, !IO) :-
    % XXX We should also create a ".bat" on Windows.
    create_launcher_shell_script(Globals, MainModuleName,
        write_java_shell_script(Globals, MainModuleName),
        Succeeded, !IO).

:- pred write_java_shell_script(globals::in, module_name::in,
    io.output_stream::in, io::di, io::uo) is det.

write_java_shell_script(Globals, MainModuleName, Stream, !IO) :-
    % In shell scripts always use / separators, even on Windows.
    get_class_dir_name(Globals, ClassDirName),
    string.replace_all(ClassDirName, "\\", "/", ClassDirNameUnix),

    get_mercury_std_libs_for_java(Globals, MercuryStdLibs),
    globals.lookup_accumulating_option(Globals, java_classpath,
        UserClasspath),
    % We prepend the .class files' directory and the current CLASSPATH.
    Java_Incl_Dirs = ["$DIR/" ++ ClassDirNameUnix] ++ MercuryStdLibs ++
        ["$CLASSPATH" | UserClasspath],
    ClassPath = string.join_list("${SEP}", Java_Incl_Dirs),

    globals.lookup_string_option(Globals, java_interpreter, Java),
    mangle_sym_name_for_java(MainModuleName, module_qual, ".", ClassName),

    list.foldl(io.write_string(Stream), [
        "#!/bin/sh\n",
        "DIR=${0%/*}\n",
        "case $WINDIR in\n",
        "   '') SEP=':' ;;\n",
        "   *)  SEP=';' ;;\n",
        "esac\n",
        "CLASSPATH=", ClassPath, "\n",
        "export CLASSPATH\n",
        "JAVA=${JAVA:-", Java, "}\n",
        "exec $JAVA jmercury.", ClassName, " \"$@\"\n"
    ], !IO).

    % NOTE: changes here may require changes to get_mercury_std_libs.
get_mercury_std_libs_for_java(Globals, !:StdLibs) :-
    !:StdLibs = [],
    globals.lookup_maybe_string_option(Globals,
        mercury_standard_library_directory, MaybeStdlibDir),
    (
        MaybeStdlibDir = yes(StdLibDir),
        grade_directory_component(Globals, GradeDir),
        % Source-to-source debugging libraries.
        globals.lookup_bool_option(Globals, source_to_source_debug,
            SourceDebug),
        (
            SourceDebug = yes,
            list.cons(StdLibDir/"lib"/GradeDir/"mer_browser.jar", !StdLibs),
            list.cons(StdLibDir/"lib"/GradeDir/"mer_mdbcomp.jar", !StdLibs),
            list.cons(StdLibDir/"lib"/GradeDir/"mer_ssdb.jar", !StdLibs)
        ;
            SourceDebug = no
        ),
        list.cons(StdLibDir/"lib"/GradeDir/"mer_std.jar", !StdLibs),
        list.cons(StdLibDir/"lib"/GradeDir/"mer_rt.jar", !StdLibs)
    ;
        MaybeStdlibDir = no
    ).

list_class_files_for_jar(Globals, MainClassFiles, ClassSubDir,
        ListClassFiles, !IO) :-
    globals.lookup_bool_option(Globals, use_subdirs, UseSubdirs),
    globals.lookup_bool_option(Globals, use_grade_subdirs, UseGradeSubdirs),
    AnySubdirs = UseSubdirs `or` UseGradeSubdirs,
    (
        AnySubdirs = yes,
        get_class_dir_name(Globals, ClassSubDir)
    ;
        AnySubdirs = no,
        ClassSubDir = dir.this_directory
    ),

    list.filter_map(make_nested_class_prefix, MainClassFiles,
        NestedClassPrefixes),
    NestedClassPrefixesSet = set.from_list(NestedClassPrefixes),

    SearchDir = ClassSubDir / "jmercury",
    FollowSymLinks = yes,
    dir.recursive_foldl2(
        accumulate_nested_class_files(NestedClassPrefixesSet),
        SearchDir, FollowSymLinks, [], Result, !IO),
    (
        Result = ok(NestedClassFiles),
        AllClassFiles0 = MainClassFiles ++ NestedClassFiles,
        % Remove the `Mercury/classs' prefix if present.
        ( ClassSubDir = dir.this_directory ->
            AllClassFiles = AllClassFiles0
        ;
            ClassSubDirSep = ClassSubDir / "",
            AllClassFiles = list.map(
                string.remove_prefix_if_present(ClassSubDirSep),
                AllClassFiles0)
        ),
        list.sort(AllClassFiles, ListClassFiles)
    ;
        Result = error(_, Error),
        unexpected(this_file, io.error_message(Error))
    ).

list_class_files_for_jar_mmake(Globals, ClassFiles, ListClassFiles) :-
    globals.lookup_bool_option(Globals, use_subdirs, UseSubdirs),
    globals.lookup_bool_option(Globals, use_grade_subdirs, UseGradeSubdirs),
    AnySubdirs = UseSubdirs `or` UseGradeSubdirs,
    (
        AnySubdirs = yes,
        get_class_dir_name(Globals, ClassSubdir),
        % Here we use the `-C' option of jar to change directory during
        % execution, then use sed to strip away the Mercury/classs/
        % prefix to the class files.
        % Otherwise, the class files would be stored as
        %   Mercury/classs/*.class
        % within the jar file, which is not what we want.
        % XXX It would be nice to avoid this dependency on sed.
        ListClassFiles = "-C " ++ ClassSubdir ++ " \\\n" ++
            "\t\t`echo "" " ++ ClassFiles ++ """" ++
            " | sed 's| '" ++ ClassSubdir ++ "/| |'`"
    ;
        AnySubdirs = no,
        ListClassFiles = ClassFiles
    ).

:- pred make_nested_class_prefix(string::in, string::out) is semidet.

make_nested_class_prefix(ClassFileName, ClassPrefix) :-
    % Nested class files are named "Class$Nested_1$Nested_2.class".
    string.remove_suffix(ClassFileName, ".class", BaseName),
    ClassPrefix = BaseName ++ "$".

:- pred accumulate_nested_class_files(set(string)::in, string::in, string::in,
    io.file_type::in, bool::out, list(string)::in, list(string)::out,
    io::di, io::uo) is det.

accumulate_nested_class_files(NestedClassPrefixes, DirName, BaseName,
        _FileType, Continue, !Acc, !IO) :-
    (
        string.sub_string_search(BaseName, "$", Dollar),
        BaseNameToDollar = string.left(BaseName, Dollar + 1),
        set.contains(NestedClassPrefixes, DirName / BaseNameToDollar)
    ->
        !:Acc = [DirName / BaseName | !.Acc]
    ;
        true
    ),
    Continue = yes.

get_env_classpath(Classpath, !IO) :-
    io.get_environment_var("CLASSPATH", MaybeCP, !IO),
    (
        MaybeCP = yes(Classpath)
    ;
        MaybeCP = no,
        io.get_environment_var("java.class.path", MaybeJCP, !IO),
        (
            MaybeJCP = yes(Classpath)
        ;
            MaybeJCP = no,
            Classpath = ""
        )
    ).

%-----------------------------------------------------------------------------%
%
% Erlang utilities
%

create_erlang_shell_script(Globals, MainModuleName, Succeeded, !IO) :-
    create_launcher_shell_script(Globals, MainModuleName,
        write_erlang_shell_script(Globals, MainModuleName),
        Succeeded, !IO).

:- pred write_erlang_shell_script(globals::in, module_name::in,
    io.output_stream::in, io::di, io::uo) is det.

write_erlang_shell_script(Globals, MainModuleName, Stream, !IO) :-
    globals.lookup_string_option(Globals, erlang_object_file_extension,
        BeamExt),
    module_name_to_file_name(Globals, MainModuleName, BeamExt,
        do_not_create_dirs, BeamFileName, !IO),
    BeamDirName = dir.dirname(BeamFileName),
    module_name_to_file_name_stem(MainModuleName, BeamBaseNameNoExt),

    % Add `-pa <dir>' option to find the standard library.
    % (-pa adds the directory to the beginning of the list of paths to search
    % for .beam files)
    grade_directory_component(Globals, GradeDir),
    globals.lookup_maybe_string_option(Globals,
        mercury_standard_library_directory, MaybeStdLibDir),
    (
        MaybeStdLibDir = yes(StdLibDir),
        StdLibBeamsPath = StdLibDir/"lib"/GradeDir/"libmer_std.beams",
        SearchStdLib = pa_option(yes, StdLibBeamsPath),
        % Added by elds_to_erlang.m
        MainFunc = "mercury__main_wrapper"
    ;
        MaybeStdLibDir = no,
        SearchStdLib = "",
        MainFunc = "main_2_p_0"
    ),

    % Add `-pa <dir>' options to find any other libraries specified by the user.
    globals.lookup_accumulating_option(Globals, mercury_library_directories,
        MercuryLibDirs0),
    MercuryLibDirs = list.map((func(LibDir) = LibDir/"lib"/GradeDir),
        MercuryLibDirs0),
    globals.lookup_accumulating_option(Globals, link_libraries,
        LinkLibrariesList0),
    list.map_foldl(find_erlang_library_path(Globals, MercuryLibDirs),
        LinkLibrariesList0, LinkLibrariesList, !IO),

    globals.lookup_string_option(Globals, erlang_interpreter, Erlang),
    SearchLibs = string.append_list(list.map(pa_option(yes),
        list.sort_and_remove_dups(LinkLibrariesList))),

    % XXX main_2_p_0 is not necessarily in the main module itself and
    % could be in a submodule.  We don't handle that yet.
    SearchProg = pa_option(no, """$DIR""/" ++ quote_arg(BeamDirName)),

    % Write the shell script.
    % Note we need to use '-extra' instead of '--' for "-flag" and
    % "+flag" arguments to be pass through to the Mercury program.
    io.write_strings(Stream, [
        "#!/bin/sh\n",
        "# Generated by the Mercury compiler.\n",
        "DIR=`dirname ""$0""`\n",
        "exec ", Erlang, " -noshell \\\n",
        SearchStdLib, SearchLibs, SearchProg,
        " -s ", BeamBaseNameNoExt, " ", MainFunc,
        " -s init stop -extra ""$@""\n"
    ], !IO).

:- pred find_erlang_library_path(globals::in, list(dir_name)::in, string::in,
    string::out, io::di, io::uo) is det.

find_erlang_library_path(Globals, MercuryLibDirs, LibName, LibPath, !IO) :-
    file_name_to_module_name(LibName, LibModuleName),
    globals.set_option(use_grade_subdirs, bool(no), Globals, NoSubdirsGlobals),
    module_name_to_lib_file_name(NoSubdirsGlobals, "lib", LibModuleName,
        ".beams", do_not_create_dirs, LibFileName, !IO),

    search_for_file_returning_dir(do_not_open_file, MercuryLibDirs,
        LibFileName, SearchResult, !IO),
    (
        SearchResult = ok(DirName),
        LibPath = DirName/LibFileName
    ;
        SearchResult = error(Error),
        LibPath = "",
        write_error_pieces_maybe_with_context(Globals, no, 0, [words(Error)],
            !IO)
    ).

:- func pa_option(bool, dir_name) = string.

pa_option(Quote, Dir0) = " -pa " ++ Dir ++ " \\\n" :-
    (
        Quote = yes,
        Dir = quote_arg(Dir0)
    ;
        Quote = no,
        Dir = Dir0
    ).

%-----------------------------------------------------------------------------%

create_launcher_shell_script(Globals, MainModuleName, Pred, Succeeded, !IO) :-
    Extension = "",
    module_name_to_file_name(Globals, MainModuleName, Extension,
        do_not_create_dirs, FileName, !IO),

    globals.lookup_bool_option(Globals, verbose, Verbose),
    maybe_write_string(Verbose, "% Generating shell script `" ++
        FileName ++ "'...\n", !IO),

    % Remove symlink in the way, if any.
    io.remove_file(FileName, _, !IO),
    io.open_output(FileName, OpenResult, !IO),
    (
        OpenResult = ok(Stream),
        Pred(Stream, !IO),
        io.close_output(Stream, !IO),
        io.call_system("chmod a+x " ++ FileName, ChmodResult, !IO),
        (
            ChmodResult = ok(Status),
            ( Status = 0 ->
                Succeeded = yes,
                maybe_write_string(Verbose, "% done.\n", !IO)
            ;
                unexpected(this_file, "chmod exit status != 0"),
                Succeeded = no
            )
        ;
            ChmodResult = error(Message),
            unexpected(this_file, io.error_message(Message)),
            Succeeded = no
        )
    ;
        OpenResult = error(Message),
        unexpected(this_file, io.error_message(Message)),
        Succeeded = no
    ).

%-----------------------------------------------------------------------------%

:- func this_file = string.

this_file = "module_cmds.m".

%-----------------------------------------------------------------------------%
:- end_module parse_tree.module_cmds.
%-----------------------------------------------------------------------------%
