%---------------------------------------------------------------------------%
% vim: ts=4 sw=4 et ft=mercury
%---------------------------------------------------------------------------%
%
:- module tim_qual3.

:- interface.

:- type test_type
    --->    error.

:- mode test_mode == out.

:- inst inst1 == ground.
