/*
** Copyright (C) 1995-1999 The University of Melbourne.
** This file may only be copied under the terms of the GNU Library General
** Public License - see the file COPYING.LIB in the Mercury distribution.
*/

/*
** mercury_type_info.h -
**	Definitions for accessing the type_infos, type_layouts, and
**	type_functors tables generated by the Mercury compiler.
**	Also contains definitions for accessing the Mercury `univ' type
**	and the Mercury `array' type.
**	Changes here may also require changes in compiler/polymorphism.m,
**	compiler/higher_order.m and library/private_builtin.m.
*/

#ifndef MERCURY_TYPE_INFO_H
#define MERCURY_TYPE_INFO_H

#include "mercury_types.h"	/* for `Word' */

/*---------------------------------------------------------------------------*/

/*
** For now, we don't give a C definition of the structures of typeinfos
** and pseudotypeinfos. We may change this later.
*/

typedef	Word	MR_TypeInfo;
typedef	Word	MR_PseudoTypeInfo;

/*---------------------------------------------------------------------------*/

/*
** Define offsets of fields in the type_ctor_info or type_info structure.
** See polymorphism.m for explanation of these offsets and how the
** type_info and type_ctor_info structures are laid out.
**
** ANY CHANGES HERE MUST BE MATCHED BY CORRESPONDING CHANGES
** TO THE DOCUMENTATION IN compiler/polymorphism.m.
**
** The current type_info representation *depends* on OFFSET_FOR_COUNT being 0.
*/

#define OFFSET_FOR_COUNT 0
#define OFFSET_FOR_UNIFY_PRED 1
#define OFFSET_FOR_INDEX_PRED 2
#define OFFSET_FOR_COMPARE_PRED 3
#define OFFSET_FOR_BASE_TYPE_LAYOUT 4
#define OFFSET_FOR_BASE_TYPE_FUNCTORS 5
#define OFFSET_FOR_TYPE_MODULE_NAME 7
#define OFFSET_FOR_TYPE_NAME 8

/*
** Define offsets of fields in the type_info structure.
*/

#define OFFSET_FOR_ARG_TYPE_INFOS 1

/*
** Where the predicate arity and args are stored in the type_info.
** They are stored in the type_info (*not* the type_ctor_info).
** This is brought about by higher-order predicates all using the
** same type_ctor_info - pred/0.
*/

#define TYPEINFO_OFFSET_FOR_PRED_ARITY 1
#define TYPEINFO_OFFSET_FOR_PRED_ARGS 2

/*---------------------------------------------------------------------------*/

/*
** Definitions for handwritten code, mostly for mercury_compare_typeinfo.
*/

#define COMPARE_EQUAL 0
#define COMPARE_LESS 1
#define COMPARE_GREATER 2

#ifdef  COMPACT_ARGS
#define	mercury__unify__typeinfo	r1
#define	mercury__unify__x		r2
#define	mercury__unify__y		r3
#define	mercury__unify__offset		0
#define	mercury__compare__typeinfo	r1
#define	mercury__compare__x		r2
#define	mercury__compare__y		r3
#define	mercury__compare__offset	0
#define	mercury__term_to_type__typeinfo	r1
#define	mercury__term_to_type__term	r2
#define	mercury__term_to_type__x	r4
#define	mercury__term_to_type__offset	1
#define unify_input1    r1
#define unify_input2    r2
#define unify_output    r1
#define compare_input1  r1
#define compare_input2  r2
#define compare_output  r1
#define index_input     r1
#define index_output    r1
#else
#define	mercury__unify__typeinfo	r2
#define	mercury__unify__x		r3
#define	mercury__unify__y		r4
#define	mercury__unify__offset		1
#define	mercury__compare__typeinfo	r1
#define	mercury__compare__x		r3
#define	mercury__compare__y		r4
#define	mercury__compare__offset	1
#define	mercury__term_to_type__typeinfo	r2
#define	mercury__term_to_type__term	r3
#define	mercury__term_to_type__x	r4
#define	mercury__term_to_type__offset	1
#define unify_input1    r2
#define unify_input2    r3
#define unify_output    r1
#define compare_input1  r2
#define compare_input2  r3
#define compare_output  r1
#define index_input     r1
#define index_output    r2
#endif

/*---------------------------------------------------------------------------*/

/*
** Definitions and macros for type_ctor_layout definition.
**
** See compiler/base_type_layout.m for more information.
**
** If we don't have enough tags, we have to encode layouts
** less densely. The make_typelayout macro does this, and
** is intended for handwritten code. Compiler generated
** code can (and does) just create two rvals instead of one. 
**
*/

/*
** Conditionally define USE_TYPE_LAYOUT.
**
** All code using type_layout structures should check to see if
** USE_TYPE_LAYOUT is defined, and give a fatal error otherwise.
** USE_TYPE_LAYOUT can be explicitly turned off with NO_TYPE_LAYOUT.
**
*/
#if !defined(NO_TYPE_LAYOUT)
	#define USE_TYPE_LAYOUT
#else
	#undef USE_TYPE_LAYOUT
#endif


/*
** Code intended for defining type_layouts for handwritten code.
**
** See library/io.m or library/builtin.m for details.
*/
#if TAGBITS >= 2
	typedef const Word *TypeLayoutField;
	#define TYPE_LAYOUT_FIELDS \
		TypeLayoutField f1,f2,f3,f4,f5,f6,f7,f8;
	#define make_typelayout(Tag, Value) \
		mkword(mktag(Tag), (Value))
#else
	typedef const Word *TypeLayoutField;
	#define TYPE_LAYOUT_FIELDS \
		TypeLayoutField f1,f2,f3,f4,f5,f6,f7,f8;
		TypeLayoutField f9,f10,f11,f12,f13,f14,f15,f16;
	#define make_typelayout(Tag, Value) \
		(const Word *) (Tag), \
		(const Word *) (Value)
#endif

/*
** Declaration for structs.
*/

#define MR_DECLARE_STRUCT(T)			\
	extern const struct T##_struct T

/*
** Typelayouts for builtins are often defined as X identical
** values, where X is the number of possible tag values.
*/

#if TAGBITS == 0
#define make_typelayout_for_all_tags(Tag, Value) \
	make_typelayout(Tag, Value)
#elif TAGBITS == 1
#define make_typelayout_for_all_tags(Tag, Value) \
	make_typelayout(Tag, Value), \
	make_typelayout(Tag, Value)
#elif TAGBITS == 2
#define make_typelayout_for_all_tags(Tag, Value) \
	make_typelayout(Tag, Value), \
	make_typelayout(Tag, Value), \
	make_typelayout(Tag, Value), \
	make_typelayout(Tag, Value)
#elif TAGBITS == 3
#define make_typelayout_for_all_tags(Tag, Value) \
	make_typelayout(Tag, Value), \
	make_typelayout(Tag, Value), \
	make_typelayout(Tag, Value), \
	make_typelayout(Tag, Value), \
	make_typelayout(Tag, Value), \
	make_typelayout(Tag, Value), \
	make_typelayout(Tag, Value), \
	make_typelayout(Tag, Value)
#endif

#if !defined(make_typelayout_for_all_tags)
#error "make_typelayout_for_all_tags is not defined for this number of tags"
#endif

/*---------------------------------------------------------------------------*/

/* 
** Tags in type_layout structures.
** 
** These definitions are intended for use in handwritten
** C code. 
**
** Some of the type-layout tags are shared.
*/

#define TYPE_CTOR_LAYOUT_CONST_TAG		0
#define TYPE_CTOR_LAYOUT_COMP_CONST_TAG	0 
#define TYPE_CTOR_LAYOUT_SIMPLE_TAG		1
#define TYPE_CTOR_LAYOUT_COMPLICATED_TAG	2
#define TYPE_CTOR_LAYOUT_EQUIV_TAG		3
#define TYPE_CTOR_LAYOUT_NO_TAG		3 

/* 
** Values in type_layout structures,
** presently the values of CONST_TAG words.
**
** Also intended for use in handwritten C code.
**
** Note that MR_TYPE_CTOR_LAYOUT_UNASSIGNED_VALUE is not yet
** used for anything.
**
** Changes in this type may need to be reflected in
** compiler/base_type_layout.m.
**
*/

enum MR_TypeLayoutValue {
	MR_TYPE_CTOR_LAYOUT_UNASSIGNED_VALUE,
	MR_TYPE_CTOR_LAYOUT_UNUSED_VALUE,
	MR_TYPE_CTOR_LAYOUT_STRING_VALUE,
	MR_TYPE_CTOR_LAYOUT_FLOAT_VALUE,
	MR_TYPE_CTOR_LAYOUT_INT_VALUE,
	MR_TYPE_CTOR_LAYOUT_CHARACTER_VALUE,
	MR_TYPE_CTOR_LAYOUT_UNIV_VALUE,
	MR_TYPE_CTOR_LAYOUT_PREDICATE_VALUE,
	MR_TYPE_CTOR_LAYOUT_VOID_VALUE,
	MR_TYPE_CTOR_LAYOUT_ARRAY_VALUE,
	MR_TYPE_CTOR_LAYOUT_TYPEINFO_VALUE,
	MR_TYPE_CTOR_LAYOUT_C_POINTER_VALUE,
	MR_TYPE_CTOR_LAYOUT_TYPECLASSINFO_VALUE
};

/* 
** Highest allowed type variable number
** (corresponds with argument number of type parameter).
**
** Should be kept in sync with the default value of MR_VARIABLE_SIZED
** in mercury_conf_params.h.
*/

#define TYPE_CTOR_LAYOUT_MAX_VARINT		1024

#define TYPEINFO_IS_VARIABLE(T)		( (Word) T <= TYPE_CTOR_LAYOUT_MAX_VARINT )

/*
** This constant is also used for other information - for
** ctor infos a small integer is used for higher order types.
** Even integers represent preds, odd represent functions.
** The arity of the pred or function can be found by dividing by
** two (integer division).
*/

#define MR_TYPE_CTOR_INFO_HO_PRED				\
	((const Word *) &mercury_data___type_ctor_info_pred_0)
#define MR_TYPE_CTOR_INFO_HO_FUNC				\
	((const Word *) &mercury_data___type_ctor_info_func_0)
#define MR_TYPE_CTOR_INFO_IS_HO_PRED(T)				\
	(T == MR_TYPE_CTOR_INFO_HO_PRED)
#define MR_TYPE_CTOR_INFO_IS_HO_FUNC(T)				\
	(T == MR_TYPE_CTOR_INFO_HO_FUNC)
#define MR_TYPE_CTOR_INFO_IS_HO(T)				\
	(T == MR_TYPE_CTOR_INFO_HO_FUNC || T == MR_TYPE_CTOR_INFO_HO_PRED)

#define MR_TYPECTOR_IS_HIGHER_ORDER(T)				\
	( (Word) T <= TYPE_CTOR_LAYOUT_MAX_VARINT )
#define MR_TYPECTOR_MAKE_PRED(Arity)				\
	( (Word) ((Integer) (Arity) * 2) )
#define MR_TYPECTOR_MAKE_FUNC(Arity)				\
	( (Word) ((Integer) (Arity) * 2 + 1) )
#define MR_TYPECTOR_GET_HOT_ARITY(T)				\
	((Integer) (T) / 2 )
#define MR_TYPECTOR_GET_HOT_NAME(T)				\
	((ConstString) ( ( ((Integer) (T)) % 2 ) ? "func" : "pred" ))
#define MR_TYPECTOR_GET_HOT_MODULE_NAME(T)				\
	((ConstString) "builtin")
#define MR_TYPECTOR_GET_HOT_TYPE_CTOR_INFO(T)			\
	((Word) ( ( ((Integer) (T)) % 2 ) ?		\
		(const Word *) &mercury_data___type_ctor_info_func_0 :	\
		(const Word *) &mercury_data___type_ctor_info_pred_0 ))

/*
** Offsets into the type_layout structure for functors and arities.
**
** Constant and enumeration values start at 0, so the functor
** is at OFFSET + const/enum value. 
** 
** Functors for simple tags are at OFFSET + arity (the functor is
** stored after all the argument info.
**
*/

#define TYPE_CTOR_LAYOUT_CONST_FUNCTOR_OFFSET		2
#define TYPE_CTOR_LAYOUT_ENUM_FUNCTOR_OFFSET		2
#define TYPE_CTOR_LAYOUT_SIMPLE_FUNCTOR_OFFSET	1

#define TYPE_CTOR_LAYOUT_SIMPLE_ARITY_OFFSET  	0
#define TYPE_CTOR_LAYOUT_SIMPLE_ARGS_OFFSET       	1

/*---------------------------------------------------------------------------*/

/* 
** Offsets for dealing with `univ' types.
**
** `univ' is represented as a two word structure.
** The first word contains the address of a type_info for the type.
** The second word contains the data.
*/

#define UNIV_OFFSET_FOR_TYPEINFO 		0
#define UNIV_OFFSET_FOR_DATA			1

/*---------------------------------------------------------------------------*/

/*
** Code for dealing with the static code addresses stored in
** type_ctor_infos. 
*/

/*
** Definitions for initialization of type_ctor_infos. If
** MR_STATIC_CODE_ADDRESSES are not available, we need to initialize
** the special predicates in the type_ctor_infos.
*/

/*
** A fairly generic static code address initializer - at least for entry
** labels.
*/
#define MR_INIT_CODE_ADDR(Base, PredAddr, Offset)			\
	do {								\
		Declare_entry(PredAddr);				\
		((Word *) (Word) &Base)[Offset]	= (Word) ENTRY(PredAddr);\
	} while (0)
			

#define MR_SPECIAL_PRED_INIT(Base, TypeId, Offset, Pred)	\
	MR_INIT_CODE_ADDR(Base, mercury____##Pred##___##TypeId, Offset)

/*
** Macros are provided here to initialize type_ctor_infos, both for
** builtin types (such as in library/builtin.m) and user
** defined C types (like library/array.m). Also, the automatically
** generated code uses these initializers.
**
** Examples of use:
**
** MR_INIT_BUILTIN_TYPE_CTOR_INFO(
** 	mercury_data__type_ctor_info_string_0, _string_);
**
** note we use _string_ to avoid the redefinition of string via #define
**
** MR_INIT_TYPE_CTOR_INFO(
** 	mercury_data_group__type_ctor_info_group_1, group__group_1_0);
** 
** MR_INIT_TYPE_CTOR_INFO_WITH_PRED(
** 	mercury_date__type_ctor_info_void_0, mercury__unused_0_0);
**
** This will initialize a type_ctor_info with a single code address.
**
**
*/

#ifndef MR_STATIC_CODE_ADDRESSES

  #define MR_MAYBE_STATIC_CODE(X)	((Integer) 0)

  #define MR_STATIC_CODE_CONST

  #ifdef USE_TYPE_TO_TERM

    #define	MR_INIT_BUILTIN_TYPE_CTOR_INFO(B, T) \
    do {								\
	MR_INIT_CODE_ADDR(B, mercury__builtin_unify##T##2_0, 		\
		OFFSET_FOR_UNIFY_PRED);					\
	MR_INIT_CODE_ADDR(B, mercury__builtin_index##T##2_0, 		\
		OFFSET_FOR_INDEX_PRED);					\
	MR_INIT_CODE_ADDR(B, mercury__builtin_compare##T##3_0, 		\
		OFFSET_FOR_COMPARE_PRED);				\
	MR_INIT_CODE_ADDR(B, mercury__builtin_type_to_term##T##2_0,	\
		OFFSET_FOR_TYPE_TO_TERM_PRED);				\
	MR_INIT_CODE_ADDR(B, mercury__builtin_term_to_type##T##2_0,	\
		OFFSET_FOR_TERM_TO_TYPE_PRED);				\
    } while (0)

    #define	MR_INIT_TYPE_CTOR_INFO_WITH_PRED(B, P)			\
    do {								\
	MR_INIT_CODE_ADDR(B, P, OFFSET_FOR_UNIFY_PRED);			\
	MR_INIT_CODE_ADDR(B, P, OFFSET_FOR_INDEX_PRED);			\
	MR_INIT_CODE_ADDR(B, P, OFFSET_FOR_COMPARE_PRED);		\
	MR_INIT_CODE_ADDR(B, P, OFFSET_FOR_TYPE_TO_TERM_PRED);		\
	MR_INIT_CODE_ADDR(B, P, OFFSET_FOR_TERM_TO_TYPE_PRED);		\
    } while (0)

    #define	MR_INIT_TYPE_CTOR_INFO(B, T) \
    do {								\
	MR_SPECIAL_PRED_INIT(B, T, OFFSET_FOR_UNIFY_PRED, Unify);	\
	MR_SPECIAL_PRED_INIT(B, T, OFFSET_FOR_INDEX_PRED, Index);	\
	MR_SPECIAL_PRED_INIT(B, T, OFFSET_FOR_COMPARE_PRED, Compare);	\
	MR_SPECIAL_PRED_INIT(B, T, OFFSET_FOR_TERM_TO_TYPE_PRED, Term_To_Type);\
	MR_SPECIAL_PRED_INIT(B, T, OFFSET_FOR_TYPE_TO_TERM_PRED, Type_To_Term);\
    } while (0)

  #else /* not USE_TYPE_TO_TERM */ 

    #define	MR_INIT_BUILTIN_TYPE_CTOR_INFO(B, T) \
    do {								\
	MR_INIT_CODE_ADDR(B, mercury__builtin_unify##T##2_0, 	\
		OFFSET_FOR_UNIFY_PRED);					\
	MR_INIT_CODE_ADDR(B, mercury__builtin_index##T##2_0, 	\
		OFFSET_FOR_INDEX_PRED);					\
	MR_INIT_CODE_ADDR(B, mercury__builtin_compare##T##3_0, 	\
		OFFSET_FOR_COMPARE_PRED);				\
    } while (0)

    #define	MR_INIT_TYPE_CTOR_INFO_WITH_PRED(B, P)			\
    do {								\
	MR_INIT_CODE_ADDR(B, P, OFFSET_FOR_UNIFY_PRED);			\
	MR_INIT_CODE_ADDR(B, P, OFFSET_FOR_INDEX_PRED);			\
	MR_INIT_CODE_ADDR(B, P, OFFSET_FOR_COMPARE_PRED);		\
    } while (0)

    #define	MR_INIT_TYPE_CTOR_INFO(B, T) \
    do {	\
	MR_SPECIAL_PRED_INIT(B, T, OFFSET_FOR_UNIFY_PRED, Unify);     \
	MR_SPECIAL_PRED_INIT(B, T, OFFSET_FOR_INDEX_PRED, Index);     \
	MR_SPECIAL_PRED_INIT(B, T, OFFSET_FOR_COMPARE_PRED, Compare); \
    } while (0)

    #endif /* not USE_TYPE_TO_TERM */

#else	/* MR_STATIC_CODE_ADDRESSES */

  #define MR_MAYBE_STATIC_CODE(X)	(X)

  #define MR_STATIC_CODE_CONST const

  #define MR_INIT_BUILTIN_TYPE_CTOR_INFO(B, T) \
	do { } while (0)

  #define MR_INIT_TYPE_CTOR_INFO_WITH_PRED(B, P) \
	do { } while (0)

  #define MR_INIT_TYPE_CTOR_INFO(B, T) \
	do { } while (0)

#endif /* MR_STATIC_CODE_ADDRESSES */

/*---------------------------------------------------------------------------*/

/*
** Macros and defintions for defining and dealing with
** type_ctor_functors.
*/

/*
** All type_functors have an indicator.
*/

#define MR_TYPE_CTOR_FUNCTORS_OFFSET_FOR_INDICATOR	((Integer) 0)

#define MR_TYPE_CTOR_FUNCTORS_INDICATOR(Functors)				\
	((Functors)[MR_TYPE_CTOR_FUNCTORS_OFFSET_FOR_INDICATOR])


/*
** Values that the indicator can take.
*/

#define MR_TYPE_CTOR_FUNCTORS_DU	((Integer) 0)
#define MR_TYPE_CTOR_FUNCTORS_ENUM	((Integer) 1)
#define MR_TYPE_CTOR_FUNCTORS_EQUIV	((Integer) 2)
#define MR_TYPE_CTOR_FUNCTORS_SPECIAL	((Integer) 3)
#define MR_TYPE_CTOR_FUNCTORS_NO_TAG	((Integer) 4)
#define MR_TYPE_CTOR_FUNCTORS_UNIV	((Integer) 5)


	/*
	** Macros to access the data in a discriminated union
	** type_functors, the number of functors, and the simple_vector
	** for functor number N (where N starts at 1). 
	*/

#define MR_TYPE_CTOR_FUNCTORS_DU_OFFSET_FOR_NUM_FUNCTORS	((Integer) 1)
#define MR_TYPE_CTOR_FUNCTORS_DU_OFFSET_FOR_FUNCTORS_VECTOR	((Integer) 2)

#define MR_TYPE_CTOR_FUNCTORS_DU_NUM_FUNCTORS(Functors)			\
	((Functors)[MR_TYPE_CTOR_FUNCTORS_DU_OFFSET_FOR_NUM_FUNCTORS])

#define MR_TYPE_CTOR_FUNCTORS_DU_FUNCTOR_N(Functor, N)			\
	((Word *) ((Functor)[						\
		MR_TYPE_CTOR_FUNCTORS_DU_OFFSET_FOR_FUNCTORS_VECTOR + N]))

	/*
	** Macros to access the data in a enumeration type_functors, the
	** number of functors, and the enumeration vector.
	*/

#define MR_TYPE_CTOR_FUNCTORS_ENUM_OFFSET_FOR_FUNCTORS_VECTOR		((Integer) 1)

#define MR_TYPE_CTOR_FUNCTORS_ENUM_NUM_FUNCTORS(Functors)			\
	MR_TYPE_CTOR_LAYOUT_ENUM_VECTOR_NUM_FUNCTORS(			\
		MR_TYPE_CTOR_FUNCTORS_ENUM_FUNCTORS((Functors)))

#define MR_TYPE_CTOR_FUNCTORS_ENUM_FUNCTORS(Functor)				\
	((Word *) ((Functor)[MR_TYPE_CTOR_FUNCTORS_ENUM_OFFSET_FOR_FUNCTORS_VECTOR]))

	/*
	** Macros to access the data in a no_tag type_functors, the
	** simple_vector for the functor (there can only be one functor
	** with no_tags).
	*/

#define MR_TYPE_CTOR_FUNCTORS_NO_TAG_OFFSET_FOR_FUNCTORS_VECTOR	((Integer) 1)

#define MR_TYPE_CTOR_FUNCTORS_NO_TAG_FUNCTOR(Functors)			\
	((Word *) ((Functors)						\
		[MR_TYPE_CTOR_FUNCTORS_NO_TAG_OFFSET_FOR_FUNCTORS_VECTOR]))

	/*
	** Macros to access the data in an equivalence type_functors,
	** the equivalent type of this type.
	*/

#define MR_TYPE_CTOR_FUNCTORS_EQUIV_OFFSET_FOR_TYPE	((Integer) 1)

#define MR_TYPE_CTOR_FUNCTORS_EQUIV_TYPE(Functors)				\
	((Functors)[MR_TYPE_CTOR_FUNCTORS_EQUIV_OFFSET_FOR_TYPE])

/*---------------------------------------------------------------------------*/

/*
** Macros and defintions for defining and dealing with the vectors
** created by type_ctor_layouts (these are the same vectors referred to
** by type_ctor_functors)
** 	- the simple_vector, describing a single functor
** 	- the enum_vector, describing an enumeration
** 	- the no_tag_vector, describing a single functor 
*/

	/*
	** Macros for dealing with enum vectors.
	*/

typedef struct {
	int enum_or_comp_const;
	Word num_sharers;		
	ConstString functor1;
/* other functors follow, num_sharers of them.
** 	ConstString functor2;
** 	...
*/
} MR_TypeLayout_EnumVector;

#define MR_TYPE_CTOR_LAYOUT_ENUM_VECTOR_IS_ENUM(Vector)			\
	((MR_TypeLayout_EnumVector *) (Vector))->enum_or_comp_const

#define MR_TYPE_CTOR_LAYOUT_ENUM_VECTOR_NUM_FUNCTORS(Vector)			\
	((MR_TypeLayout_EnumVector *) (Vector))->num_sharers

#define MR_TYPE_CTOR_LAYOUT_ENUM_VECTOR_FUNCTOR_NAME(Vector, N)		\
	( (&((MR_TypeLayout_EnumVector *)(Vector))->functor1) [N] )


	/*
	** Macros for dealing with simple vectors.
	*/

#define MR_TYPE_CTOR_LAYOUT_SIMPLE_VECTOR_OFFSET_FOR_ARITY		((Integer) 0)
#define MR_TYPE_CTOR_LAYOUT_SIMPLE_VECTOR_OFFSET_FOR_ARGS		((Integer) 1)
	/* Note, these offsets are from the end of the args */
#define MR_TYPE_CTOR_LAYOUT_SIMPLE_VECTOR_OFFSET_FOR_FUNCTOR_NAME	((Integer) 1)
#define MR_TYPE_CTOR_LAYOUT_SIMPLE_VECTOR_OFFSET_FOR_FUNCTOR_TAG	((Integer) 2)

#define MR_TYPE_CTOR_LAYOUT_SIMPLE_VECTOR_ARITY(V)				\
		((V)[MR_TYPE_CTOR_LAYOUT_SIMPLE_VECTOR_OFFSET_FOR_ARITY])

#define MR_TYPE_CTOR_LAYOUT_SIMPLE_VECTOR_ARGS(V)				\
		(V + MR_TYPE_CTOR_LAYOUT_SIMPLE_VECTOR_OFFSET_FOR_ARGS)

#define MR_TYPE_CTOR_LAYOUT_SIMPLE_VECTOR_FUNCTOR_NAME(V)			\
		((String) ((V)[MR_TYPE_CTOR_LAYOUT_SIMPLE_VECTOR_ARITY(V) +	\
			MR_TYPE_CTOR_LAYOUT_SIMPLE_VECTOR_OFFSET_FOR_FUNCTOR_NAME]))

#define MR_TYPE_CTOR_LAYOUT_SIMPLE_VECTOR_TAG(V)				\
		((Word) ((V)[MR_TYPE_CTOR_LAYOUT_SIMPLE_VECTOR_ARITY(V) +	\
			MR_TYPE_CTOR_LAYOUT_SIMPLE_VECTOR_OFFSET_FOR_FUNCTOR_TAG]))

	/*
	** Macros for dealing with complicated vectors.
	*/

typedef struct {
	Word num_sharers;		
	Word simple_vector1;
/* other simple_vectors follow, num_sharers of them.
**	Word simple_vector2;
** 	...
*/
} MR_TypeLayout_ComplicatedVector;

#define MR_TYPE_CTOR_LAYOUT_COMPLICATED_VECTOR_NUM_SHARERS(Vector) 	\
	((MR_TypeLayout_ComplicatedVector *) (Vector))->num_sharers

#define MR_TYPE_CTOR_LAYOUT_COMPLICATED_VECTOR_GET_SIMPLE_VECTOR(Vector, N) 	\
	( (Word *) strip_tag((&((MR_TypeLayout_ComplicatedVector *)	\
		(Vector))->simple_vector1) [N]) )
		
	/* 
	** Macros for dealing with no_tag vectors 
	**
	** (Note, we know the arity is 1).
	*/

typedef struct {
	int is_no_tag;
	Word arg;
	ConstString name;
} MR_TypeLayout_NoTagVector;

#define MR_TYPE_CTOR_LAYOUT_NO_TAG_VECTOR_IS_NO_TAG(Vector)			\
		((MR_TypeLayout_NoTagVector *) (Vector))->is_no_tag

#define MR_TYPE_CTOR_LAYOUT_NO_TAG_VECTOR_ARITY(Vector)			\
		(1)

#define MR_TYPE_CTOR_LAYOUT_NO_TAG_VECTOR_ARGS(Vector)			\
		&(((MR_TypeLayout_NoTagVector *) (Vector))->arg)
		
#define MR_TYPE_CTOR_LAYOUT_NO_TAG_VECTOR_FUNCTOR_NAME(Vector)		\
		((MR_TypeLayout_NoTagVector *) (Vector))->name

	/* 
	** Macros for dealing with equivalent vectors 
	*/	

typedef struct {
	int is_no_tag;		/* might be a no_tag */
	Word equiv_type;
} MR_TypeLayout_EquivVector;

#define MR_TYPE_CTOR_LAYOUT_EQUIV_OFFSET_FOR_TYPE	((Integer) 1)

#define MR_TYPE_CTOR_LAYOUT_EQUIV_IS_EQUIV(Vector)				\
		(!((MR_TypeLayout_EquivVector *) (Vector))->is_no_tag)

#define MR_TYPE_CTOR_LAYOUT_EQUIV_TYPE(Vector)				\
		((MR_TypeLayout_EquivVector *) (Vector))->equiv_type

/*---------------------------------------------------------------------------*/


	/* 
	** Macros for retreiving things from type_infos and
	** type_ctor_infos
	*/

#define MR_TYPEINFO_GET_TYPE_CTOR_INFO(TypeInfo)				\
		((*TypeInfo) ? (Word *) *TypeInfo : (Word *) (Word) TypeInfo)

#define MR_TYPEINFO_GET_HIGHER_ARITY(TypeInfo)				\
		((Integer) (Word *) (TypeInfo)[TYPEINFO_OFFSET_FOR_PRED_ARITY]) 

#define MR_TYPE_CTOR_INFO_GET_TYPE_CTOR_FUNCTORS(BaseTypeInfo)			\
		((Word *) (BaseTypeInfo)[OFFSET_FOR_BASE_TYPE_FUNCTORS])

#define MR_TYPE_CTOR_INFO_GET_TYPE_CTOR_LAYOUT(BaseTypeInfo)			\
		((Word *) (BaseTypeInfo)[OFFSET_FOR_BASE_TYPE_LAYOUT])

#define MR_TYPE_CTOR_INFO_GET_TYPE_CTOR_LAYOUT_ENTRY(BaseTypeInfo, Tag)	\
		(MR_TYPE_CTOR_INFO_GET_TYPE_CTOR_LAYOUT(BaseTypeInfo)[(Tag)])

#define MR_TYPE_CTOR_INFO_GET_TYPE_ARITY(BaseTypeInfo)			\
		(((Word *) (BaseTypeInfo))[OFFSET_FOR_COUNT])

#define MR_TYPE_CTOR_INFO_GET_TYPE_NAME(BaseTypeInfo)			\
		(((String *) (BaseTypeInfo))[OFFSET_FOR_TYPE_NAME])

#define MR_TYPE_CTOR_INFO_GET_TYPE_MODULE_NAME(BaseTypeInfo)		\
		(((String *) (BaseTypeInfo))[OFFSET_FOR_TYPE_MODULE_NAME])

/*---------------------------------------------------------------------------*/

#if 0

	/* XXX: We should use structs to represent the various
	** data structures in the type_ctor_*
	**
	** To implement this: 
	** 	1. The code that uses the data in the library and
	** 	   runtime should be modified to use the above access
	** 	   macros
	** 	2. Then we can simplify the ordering of the data
	** 	   structures (for example, put variable length fields
	** 	   last)
	** 	3. Then we can create structs for them.
	**
	** Some examples are below, (no guarantees of correctness).
	**
	** Note that enum_vectors have already been handled in this way.
	*/

        /*
        **         ** IMPORTANT: the layout in memory of the following
        **         structs must match the way that the Mercury compiler
        **         generates code for them.
        */         


	/*
	** Structs defining the structure of type_ctor_infos.
	** A type_ctor_info describes the structure of a particular
	** type constructor.  One of these is generated for every
	** `:- type' declaration.
	**
	** XXX this is not used yet but we are aiming towards
	** this structure.
	*/

typedef struct {
	int arity;
	Code *unify_pred;
	Code *index_pred;
	Code *compare_pred;
		/* 
		** The representation that is used for this
		** constructor -- e.g. an enumeration, or a builtin
		** type, or a no-tag type, etc.
		*/
	MR_TypeCtorRepresentation type_ctor_rep;
		/*
		** The names, arity and argument types of all the
		** functors of this type if it is some sort of
		** discriminated union.
		*/
	MR_TypeCtorFunctors type_ctor_functors;
		/*
		** The meanings of the primary tags of this type,
		** if it is a discriminated union.
		*/
	MR_TypeCtorLayout type_ctor_layout;
	String type_ctor_name;
	String type_ctor_module_name;
} MR_TypeCtorInfo;

typedef struct {
	Word arity;
	Word arg1;		
/* other arguments follow, there are arity of them,
** then followed by functor name, and functor tag.
** 	Word arg2;
** 	...
** 	Word argarity;
**	ConstString functorname;
**	Word tag;
*/
} MR_TypeLayout_SimpleVector;


typedef struct {
	Word arity;
	Word arg_pseudo_type_infos[1]; /* variable-sized array */
                        /* actualy length is `arity', not 1 */
} MR_TypeLayout_part1;

typedef struct {
                ConstString name;
                Word arg_layouts[1]; /* variable-sized array */
                        /* actualy length is `arity', not 1 */
} MR_TypeLayout_part2;
typedef MR_TypeLayout_part1 MR_TypeLayout;

#endif


/*
** definitions for accessing the representation of the
** Mercury typeclass_info
*/

#define	MR_typeclass_info_instance_arity(tci) \
	((Integer)(*(Word **)(tci))[0])
#define	MR_typeclass_info_class_method(tci, n) \
	((Code *)(*(Word **)tci)[(n)])
#define	MR_typeclass_info_arg_typeclass_info(tci, n) \
	(((Word *)(tci))[(n)])

	/*
	** The following have the same definitions. This is because 
	** the call to MR_typeclass_info_type_info must already have the
	** number of superclass_infos for the class added to it
	*/
#define	MR_typeclass_info_superclass_info(tci, n) \
	(((Word *)(tci))[MR_typeclass_info_instance_arity(tci) + (n)])
#define	MR_typeclass_info_type_info(tci, n) \
	(((Word *)(tci))[MR_typeclass_info_instance_arity(tci) + (n)])

/*---------------------------------------------------------------------------*/

Word * MR_create_type_info(Word *, Word *);
int MR_compare_type_info(Word, Word);
Word MR_collapse_equivalences(Word);

/* 
** definitions for creating type infos from pseudo_type_info's
*/

/* for make_type_info(), we keep a list of allocated memory cells */
struct MR_MemoryCellNode {
	void *data;
	struct MR_MemoryCellNode *next;
};
typedef struct MR_MemoryCellNode *MR_MemoryList;

Word * MR_make_type_info(const Word *term_type_info, 
	const Word *arg_pseudo_type_info, MR_MemoryList *allocated);
void MR_deallocate(MR_MemoryList allocated_memory_cells);

/*---------------------------------------------------------------------------*/

/*
** defintions and functions for categorizing data representations.
*/

/*
** MR_DataRepresentation is the representation for a particular type
** constructor.  For the cases of MR_TYPE_CTOR_REP_DU the exact
** representation depends on the tag value -- lookup the tag value in
** type_ctor_layout to find out this information.
**
** 
*/
enum MR_TypeCtorRepresentation {
	MR_TYPE_CTOR_REP_ENUM,
	MR_TYPE_CTOR_REP_DU,
	MR_TYPE_CTOR_REP_NOTAG,
	MR_TYPE_CTOR_REP_EQUIV,
	MR_TYPE_CTOR_REP_EQUIV_VAR,
	MR_TYPE_CTOR_REP_INT,
	MR_TYPE_CTOR_REP_CHAR,
	MR_TYPE_CTOR_REP_FLOAT,
	MR_TYPE_CTOR_REP_STRING,
	MR_TYPE_CTOR_REP_PRED,
	MR_TYPE_CTOR_REP_UNIV,
	MR_TYPE_CTOR_REP_VOID,
	MR_TYPE_CTOR_REP_C_POINTER,
	MR_TYPE_CTOR_REP_TYPEINFO,
	MR_TYPE_CTOR_REP_TYPECLASSINFO,
	MR_TYPE_CTOR_REP_ARRAY,
	MR_TYPE_CTOR_REP_UNKNOWN
};

/*
** If the MR_TypeCtorRepresentation is MR_TYPE_CTOR_REP_DU, we have a
** discriminated union type (other than a no-tag or enumeration).  Each
** tag may have a different representation.
*/
enum MR_DiscUnionTagRepresentation {
	MR_DISCUNIONTAG_SHARED_LOCAL,
	MR_DISCUNIONTAG_UNSHARED,
	MR_DISCUNIONTAG_SHARED_REMOTE
};

/*
** MR_DataRepresentation is the representation for a particular value
** of a type with this constructor.  It is similar to the
** MR_TypeCtorRepresentaion but you need to know the primary tag value
** (and, therefore, must have the data around to examine) to tell the
** different cases for discriminated unions apart.
**
** These have been ordered so that the most similar cases are next
** to each other, so a switch on this type can exploit fallthrough
** to cut down on code duplication.
** 
** XXX this type will be replaced by a combination of MR_TypeCtorRepresentaion
** and MR_DiscUnionTagRepresentation.
*/
enum MR_DataRepresentation {
	MR_DATAREP_ENUM,
	MR_DATAREP_COMPLICATED_CONST,
	MR_DATAREP_COMPLICATED,
	MR_DATAREP_SIMPLE,
	MR_DATAREP_NOTAG,
	MR_DATAREP_EQUIV,
	MR_DATAREP_EQUIV_VAR,
	MR_DATAREP_INT,
	MR_DATAREP_CHAR,
	MR_DATAREP_FLOAT,
	MR_DATAREP_STRING,
	MR_DATAREP_PRED,
	MR_DATAREP_UNIV,
	MR_DATAREP_VOID,
	MR_DATAREP_ARRAY,
	MR_DATAREP_TYPEINFO,
	MR_DATAREP_C_POINTER,
	MR_DATAREP_UNKNOWN,
	MR_DATAREP_TYPECLASSINFO
};


/*
** Return the data representation used by the data with the given
** functors_indicator and layout_entry.
**
** functors_indicator is part of the type_ctor_functors data structure.
** layout_entry is the type_ctor_layout entry corresponding to the
** primary tag of the data.
**
*/
enum MR_DataRepresentation MR_categorize_data(Word functors_indicator,
		Word layout_entry);

/*---------------------------------------------------------------------------*/
#endif /* not MERCURY_TYPEINFO_H */
