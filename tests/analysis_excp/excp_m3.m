%---------------------------------------------------------------------------%
% vim: ts=4 sw=4 et ft=mercury
%---------------------------------------------------------------------------%

:- module excp_m3.
:- interface.

:- pred ccc(int::in) is det.

%---------------------------------------------------------------------------%

:- implementation.

:- import_module excp_m1.

:- pragma no_inline(ccc/1).

ccc(N) :-
    aaa2(N).
