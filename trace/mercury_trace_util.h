/*
** Copyright (C) 1998,2000-2002, 2004-2005 The University of Melbourne.
** This file may only be copied under the terms of the GNU Library General
** Public License - see the file COPYING.LIB in the Mercury distribution.
*/

/*
** This module provides utility functions for the debugger.
**
** This header files defines macros for dealing with registers.
** These macros assume, and enforce, the conventions described
** in trace/README.
*/

#ifndef MERCURY_TRACE_UTIL_H
#define MERCURY_TRACE_UTIL_H

#include "mercury_std.h"		/* for MR_bool     */
#include "mercury_float.h"		/* for MR_Float    */
#include "mercury_types.h"		/* for MR_Word etc */
#include "mercury_library_types.h"	/* for MercuryFile */
#include <stdio.h>			/* for FILE        */
#include "mercury_trace.h"		/* for MR_Event_Details */

/*
** MR_c_file_to_mercury_file is used to convert MR_mdb_in and MR_mdb_out
** into Mercury streams suitable for use by the browser.
*/
extern	void	MR_c_file_to_mercury_file(FILE *c_file,
			MercuryFile *mercury_file);

/*
** MR_trace_is_natural_number checks whether the given word contains a natural
** number, i.e. a sequence of digits. If yes, it puts the value of the number
** in *value and returns MR_TRUE, otherwise it returns MR_FALSE.
**
** MR_trace_is_integer is similar, but it also allows an initial minus sign
** to denote a negative number.
**
** MR_trace_is_float is similar again, but it also allows an optional
** fractional part.
**
** XXX None of these functions are robust if given numbers too large for their
** type. MR_trace_is_integer doesn't even work for MININT.
*/

extern	MR_bool	MR_trace_is_natural_number(const char *word, int *value);

extern	MR_bool	MR_trace_is_integer(const char *word, MR_Integer *value);

extern	MR_bool	MR_trace_is_float(const char *word, MR_Float *value);

/*
** These functions print the values of sets of Mercury abstract machine
** registers. Their main use is low level debugging, including debugging
** the debugger itself.
*/

extern	void	MR_print_stack_regs(FILE *fp, MR_Word *saved_regs);
extern	void	MR_print_heap_regs(FILE *fp, MR_Word *saved_regs);
extern	void	MR_print_tabling_regs(FILE *fp, MR_Word *saved_regs);
extern	void	MR_print_succip_reg(FILE *fp, MR_Word *saved_regs);
extern	void	MR_print_r_regs(FILE *fp, MR_Word *saved_regs);
extern	void	MR_print_debug_vars(FILE *fp, MR_Event_Details *event_details);

#endif /* MERCURY_TRACE_UTIL_H */
