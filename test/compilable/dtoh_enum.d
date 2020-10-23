/*
REQUIRED_ARGS: -HC -c -o-
PERMUTE_ARGS:
TEST_OUTPUT:
---
// Automatically generated by Digital Mars D Compiler

#pragma once

#include <stddef.h>
#include <stdint.h>


struct Foo;
struct FooCpp;

enum : int32_t { Anon = 10 };

enum : bool { Anon2 = true };

static const char* const Anon3 = "wow";

enum class Enum
{
    One = 0,
    Two = 1,
};

enum class EnumDefaultType
{
    One = 1,
    Two = 2,
};

enum class EnumWithType : int8_t
{
    One = 1,
    Two = 2,
};

enum
{
    AnonOne = 1,
    AnonTwo = 2,
};

enum : int64_t
{
    AnonWithTypeOne = 1LL,
    AnonWithTypeTwo = 2LL,
};

namespace EnumWithStringType
{
    static const char* const One = "1";
    static const char* const Two = "2";
};

namespace EnumWStringType
{
    static const char16_t* const One = u"1";
};

namespace EnumDStringType
{
    static const char32_t* const One = U"1";
};

namespace EnumWithImplicitType
{
    static const char* const One = "1";
    static const char* const Two = "2";
};

namespace
{
    static const char* const AnonWithStringOne = "1";
    static const char* const AnonWithStringTwo = "2";
};

enum : int32_t { AnonMixedOne = 1 };
enum : int64_t { AnonMixedTwo = 2LL };
static const char* const AnonMixedA = "a";


enum class STC
{
    a = 1,
    b = 2,
};

static STC const STC_D = (STC)3;

namespace MyEnum
{
    static Foo const A = Foo(42);
    static Foo const B = Foo(84);
};

static MyEnum const test = Foo(42);

struct FooCpp
{
    int32_t i;
    FooCpp() :
        i()
    {
    }
};

namespace MyEnumCpp
{
    static FooCpp const A = FooCpp(42);
    static FooCpp const B = FooCpp(84);
};

static MyEnum const testCpp = Foo(42);

enum class opaque;
enum class typedOpaque : int64_t;
---
*/

enum Anon = 10;
enum Anon2 = true;
enum Anon3 = "wow";

enum Enum
{
    One,
    Two
}

enum EnumDefaultType : int
{
    One = 1,
    Two = 2
}

enum EnumWithType : byte
{
    One = 1,
    Two = 2
}

enum
{
    AnonOne = 1,
    AnonTwo = 2
}

enum : long
{
    AnonWithTypeOne = 1,
    AnonWithTypeTwo = 2
}

enum EnumWithStringType : string
{
    One = "1",
    Two = "2"
}

enum EnumWStringType : wstring
{
    One = "1"
}

enum EnumDStringType : dstring
{
    One = "1"
}

enum EnumWithImplicitType
{
    One = "1",
    Two = "2"
}

enum : string
{
    AnonWithStringOne = "1",
    AnonWithStringTwo = "2"
}

enum
{
    AnonMixedOne = 1,
    long AnonMixedTwo = 2,
    string AnonMixedA = "a"
}

enum STC
{
    a = 1,
    b = 2,
}

enum STC_D = STC.a | STC.b;

struct Foo { int i; }
enum MyEnum { A = Foo(42), B = Foo(84) }
enum test = MyEnum.A;

extern(C++) struct FooCpp { int i; }
enum MyEnumCpp { A = FooCpp(42), B = FooCpp(84) }
enum testCpp = MyEnum.A;

// currently unsupported enums
enum b = [1, 2, 3];
enum c = [2: 3];

extern(C) void foo();
enum d = &foo;

immutable bool e_b;
enum e = &e_b;

enum opaque;
enum typedOpaque : long;
enum arrayOpaque : int[4]; // Cannot be exported to C++
