%---------------------------------------------------------------------------%
% vim: ts=4 sw=4 et ft=mercury
%---------------------------------------------------------------------------%

:- module excp_m2.
:- interface.

:- pred bbb(int::in) is det.

%---------------------------------------------------------------------------%

:- implementation.

:- import_module excp_m3.

:- pragma no_inline(bbb/1).

bbb(N) :-
    ccc(N).
