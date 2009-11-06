/**Relatively low-level primitives on which to build higher-level math/stat
 * functionality.  Some are used internally, some are just things that may be
 * useful to users of this library.  This module is starting to take on the
 * appearance of a small utility library.
 *
 * Note:  In several functions in this module that return arrays, the last
 * parameter is an optional buffer for storing the return value.  If this
 * parameter is ommitted or the buffer is not large enough, one will be
 * allocated on the GC heap.
 *
 * Author:  David Simcha*/
 /*
 * License:
 * Boost Software License - Version 1.0 - August 17th, 2003
 *
 * Permission is hereby granted, free of charge, to any person or organization
 * obtaining a copy of the software and accompanying documentation covered by
 * this license (the "Software") to use, reproduce, display, distribute,
 * execute, and transmit the Software, and to prepare derivative works of the
 * Software, and to permit third-parties to whom the Software is furnished to
 * do so, all subject to the following:
 *
 * The copyright notices in the Software and this entire statement, including
 * the above license grant, this restriction and the following disclaimer,
 * must be included in all copies of the Software, in whole or in part, and
 * all derivative works of the Software, unless such copies or derivative
 * works are solely in the form of machine-executable object code generated by
 * a source language processor.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE, TITLE AND NON-INFRINGEMENT. IN NO EVENT
 * SHALL THE COPYRIGHT HOLDERS OR ANYONE DISTRIBUTING THE SOFTWARE BE LIABLE
 * FOR ANY DAMAGES OR OTHER LIABILITY, WHETHER IN CONTRACT, TORT OR OTHERWISE,
 * ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 */
module dstats.base;

public import std.math, std.traits, dstats.gamma, dstats.alloc;
private import dstats.sort, std.c.stdlib, std.bigint, std.typecons,
               std.functional, std.algorithm, std.range, std.bitmanip,
               std.stdio, std.contracts, std.conv;

import std.string : strip;
import std.conv : to;

immutable real[] staticLogFacTable;

private enum size_t staticFacTableLen = 10_000;

static this() {
    // Allocating on heap instead of static data segment to avoid
    // false pointer GC issues.
    real[] sfTemp = new real[staticFacTableLen];
    sfTemp[0] = 0;
    for(uint i = 1; i < staticFacTableLen; i++) {
        sfTemp[i] = sfTemp[i - 1] + log(i);
    }
    staticLogFacTable = cast(immutable) sfTemp;
}

version(unittest) {
    import std.stdio, std.algorithm, std.random, std.file;

    void main (){}
}

/** Tests whether T is an input range whose elements can be implicitly
 * converted to reals.*/
template realInput(T) {
    enum realInput = isInputRange!(T) && is(ElementType!(T) : real);
}

// See Bugzilla 2873.  This can be removed once that's fixed.
template hasLength(R) {
    enum bool hasLength = is(typeof(R.init.length) : ulong) ||
                      is(typeof(R.init.length()) : ulong);
}


/**Tests whether T can be iterated over using foreach.  This is a superset
 * of isInputRange, as it also accepts things that use opApply, builtin
 * arrays, builtin associative arrays, etc.  Useful when all you need is
 * lowest common denominator iteration functionality and don't care about
 * more advanced range features.*/
template isIterable(T)
{
    static if (is(typeof({foreach(elem; T.init) {}}))) {
        enum bool isIterable = true;
    } else {
        enum bool isIterable = false;
    }
}

unittest {
    struct Foo {  // For testing opApply.

        int opApply(int delegate(ref uint) dg) { assert(0); }
    }

    static assert(isIterable!(uint[]));
    static assert(!isIterable!(uint));
    static assert(isIterable!(Foo));
    static assert(isIterable!(uint[string]));
    static assert(isIterable!(Chain!(uint[], uint[])));
}

/**Determine the iterable type of any iterable object, regardless of whether
 * it uses ranges, opApply, etc.  This is typeof(elem) if one does
 * foreach(elem; T.init) {}.*/
template IterType(T) {
    alias ReturnType!(
        {
            foreach(elem; T.init) {
                return elem;
            }
            assert(0);
        }) IterType;
}

unittest {
    struct Foo {  // For testing opApply.
        // For testing.

        int opApply(int delegate(ref uint) dg) { assert(0); }
    }

    static assert(is(IterType!(uint[]) == uint));
    static assert(is(IterType!(Foo) == uint));
    static assert(is(IterType!(uint[string]) == uint));
    static assert(is(IterType!(Chain!(uint[], uint[])) == uint));
}

/**Tests whether T is iterable and has elements of a type implicitly
 * convertible to real.*/
template realIterable(T) {
    enum realIterable = isIterable!(T) && is(IterType!(T) : real);
}

/**Writes the contents of an input range to an output range.
 *
 * Returns:  The output range.*/
O mate(I, O)(I input, O output)
if(isInputRange!(I) && isOutputRange!(O, ElementType!(I))) {
    foreach(elem; input) {
        output.put(elem);
    }
    return output;
}

/**Bins data into nbin equal width bins, indexed from
 * 0 to nbin - 1, with 0 being the smallest bin, etc.
 * The values returned are the counts for each bin.  Returns results on the GC
 * heap by default, but uses TempAlloc stack if alloc == Alloc.STACK.
 *
 * Works with any forward range with elements implicitly convertible to real.*/
Ret[] binCounts(Ret = uint, T)(T data, uint nbin, Ret[] buf = null)
if(isForwardRange!(T) && realInput!(T))
in {
    assert(nbin > 0);
} body {
    alias Unqual!(ElementType!(T)) E;
    E min = data.front, max = data.front;
    foreach(elem; data) {
        if(elem > max)
            max = elem;
        else if(elem < min)
            min = elem;
    }
    E range = max - min;

    Ret[] bins;
    if(buf.length < nbin) {
        bins = new Ret[nbin];
    } else {
        bins = buf[0..nbin];
        bins[] = 0;
    }

    foreach(elem; data) {
        // Using the truncation as a feature.
        uint whichBin = cast(uint) ((elem - min) * nbin / range);

        // Handle edge case by putting largest item in largest bin.
        if(whichBin == nbin)
            whichBin--;

        bins[whichBin]++;
    }

    return bins;
}

unittest {
    double[] data = [0.0, .01, .03, .05, .11, .3, .5, .7, .89, 1];
    auto res = binCounts(data, 10);
    assert(res == [4U, 1, 0, 1, 0, 1, 0, 1, 1, 1]);

    auto buf = new uint[10];
    foreach(ref elem; buf) {
        elem = uniform(0, 34534);
    }

    res = binCounts(data, 10, buf);
    assert(res == [4U, 1, 0, 1, 0, 1, 0, 1, 1, 1]);
    TempAlloc.free;
    writeln("Passed binCounts unittest.");
}

/**Bins data into nbin equal width bins, indexed from
 * 0 to nbin - 1, with 0 being the smallest bin, etc.
 * The values returned are the bin index for each element.
 *
 * Default return type is ubyte, because in the dstats.infotheory,
 * entropy() and related functions specialize on ubytes, and become
 * substandially faster.  However, if you're using more than 255 bins,
 * you'll have to provide a different return type as a template parameter.*/
Ret[] bin(Ret = ubyte, T)(T data, uint nbin, Ret[] buf = null)
if(isForwardRange!(T) && realInput!(T) && isIntegral!(Ret))
in {
    assert(nbin > 0);
} body {
    // This condition is too important, too non-obvious and too cheap to check
    // to be turned off in release mode:
    enforce(nbin <= (cast(uint) Ret.max) + 1, "Cannot bin into " ~
        to!string(nbin) ~ " bins and store the results in a " ~
        Ret.stringof ~ ".");

    alias ElementType!(T) E;
    Unqual!(E) min = data.front, max = data.front;
    auto dminmax = data;
    dminmax.popFront;
    foreach(elem; dminmax) {
        if(elem > max)
            max = elem;
        else if(elem < min)
            min = elem;
    }
    E range = max - min;

    Ret[] bins;
    if(buf.length < data.length) {
        bins = newVoid!(Ret)(data.length);
    } else {
        bins = buf[0..data.length];
    }

    foreach(i, elem; data) {
        // Using the truncation as a feature.
        uint whichBin = cast(uint) ((elem - min) * nbin / range);

        // Handle edge case by putting largest item in largest bin.
        if(whichBin == nbin)
            whichBin--;

        bins[i] = cast(Ret) whichBin;
    }

    return bins;
}

unittest {
    mixin(newFrame);
    double[] data = [0.0, .01, .03, .05, .11, .3, .5, .7, .89, 1];
    auto res = bin(data, 10);
    assert(res == [cast(ubyte) 0, 0, 0, 0, 1, 3, 5, 7, 8, 9]);

    auto buf = new ubyte[20];
    foreach(ref elem; buf) {
        elem = cast(ubyte) uniform(0U, 255);
    }

    res = bin(data, 10, buf);
    assert(res == [cast(ubyte) 0, 0, 0, 0, 1, 3, 5, 7, 8, 9]);

    // Make sure this throws:
    try {
        auto foo = bin( seq(0U, 1_000U), 512);
        assert(0);
    } catch(Exception e) {
        // It's supposed to throw.
    }

    writeln("Passed bin unittest.");
}

/**Bins data into nbin equal frequency bins, indexed from
 * 0 to nbin - 1, with 0 being the smallest bin, etc.
 * The values returned are the bin index for each element.
 *
 * Default return type is ubyte, because in the dstats.infotheory,
 * entropy() and related functions specialize on ubytes, and become
 * substandially faster.  However, if you're using more than 256 bins,
 * you'll have to provide a different return type as a template parameter.*/
Ret[] frqBin(Ret = ubyte, T)(T data, uint nbin, Ret[] buf = null)
if(realInput!(T) && isForwardRange!(T) && hasLength!(T) && isIntegral!(Ret))
in {
    assert(nbin > 0);
    assert(nbin <= data.length);
} body {
    // This condition is too important, too non-obvious and too cheap to check
    // to be turned off in release mode:
    enforce(nbin <= (cast(uint) Ret.max) + 1, "Cannot bin into " ~
        to!string(nbin) ~ " bins and store the results in a " ~
        Ret.stringof ~ ".");

    Ret[] result;
    if(buf.length < data.length) {
        result = newVoid!(Ret)(data.length);
    } else {
        result = buf[0..data.length];
    }

    auto perm = newStack!(size_t)(data.length);
    scope(exit) TempAlloc.free;

    foreach(i, ref e; perm) {
        e = i;
    }

    static if(isRandomAccessRange!(T)) {
        bool compare(size_t lhs, size_t rhs) {
            return data[lhs] < data[rhs];
        }

        qsort!compare(perm);
    } else {
        auto dd = tempdup(data);
        qsort(dd, perm);
        TempAlloc.free;
    }

    uint rem = data.length % nbin;
    Ret bin = 0;
    uint i = 0, frq = data.length / nbin;
    while(i < data.length) {
        foreach(j; 0..(bin < rem) ? frq + 1 : frq) {
            result[perm[i++]] = bin;
        }
        bin++;
    }
    return result;
}

unittest {
    double[] data = [5U, 1, 3, 8, 30, 10, 7];
    auto res = frqBin(data, 3);
    assert(res == [cast(ubyte) 0, 0, 0, 1, 2, 2, 1]);
    data = [3, 1, 4, 1, 5, 9, 2, 6, 5];

    auto buf = new ubyte[32];
    foreach(i, ref elem; buf) {
        elem = cast(ubyte) i;
    }

    res = frqBin(data, 4, buf);
    assert(res == [cast(ubyte) 1, 0, 1, 0, 2, 3, 0, 3, 2]);
    data = [3U, 1, 4, 1, 5, 9, 2, 6, 5, 3, 4, 8, 9, 7, 9, 2];
    res = frqBin(data, 4);
    assert(res == [cast(ubyte) 1, 0, 1, 0, 2, 3, 0, 2, 2, 1, 1, 3, 3, 2, 3, 0]);

    // Make sure this throws:
    try {
        auto foo = frqBin( seq(0U, 1_000U), 512);
        assert(0);
    } catch(Exception e) {
        // It's supposed to throw.
    }

    writeln("Passed frqBin unittest.");
}

/**Generates a sequence from [start..end] by increment.  Includes start,
 * excludes end.  Does so eagerly as an array.
 *
 * Examples:
 * ---
 * auto s = seq(0, 5);
 * assert(s == [0, 1, 2, 3, 4]);
 * ---
 */
CommonType!(T, U)[] seq(T, U, V = uint)(T start, U end, V increment = 1U) {
    alias CommonType!(T, U) R;
    auto output = newVoid!(R)(cast(size_t) ((end - start) / increment));

    size_t count = 0;
    for(T i = start; i < end; i += increment) {
        output[count++] = i;
    }
    return output;
}

unittest {
    auto s = seq(0, 5);
    assert(s == [0, 1, 2, 3, 4]);
    writeln("Passed seq test.");
}

/**Given an input array, outputs an array containing the rank from
 * [1, input.length] corresponding to each element.  Ties are dealt with by
 * averaging.  This function does not reorder the input range.
 * Return type is float[] by default, but if you are sure you have no ties,
 * ints can be used for efficiency, and if you need more precision when
 * averaging ties, you can use double or real.
 *
 * Works with any input range.
 *
 * Examples:
 * ---
 * uint[] test = [3, 5, 3, 1, 2];
 * assert(rank(test) == [3.5f, 5f, 3.5f, 1f, 2f]);
 * assert(test == [3U, 5, 3, 1, 2]);
 * ---*/
Ret[] rank(alias compFun = "a < b", Ret = float, T)(T input, Ret[] buf = null)
if(isInputRange!(T)) {
    static if(!isRandomAccessRange!(T) || !hasLength!(T)) {
        return rankSort!(compFun, Ret)( tempdup(input), buf);
    } else {
        mixin(newFrame);
        size_t[] indices = newStack!size_t(input.length);
        foreach(i, ref elem; indices) {
            elem = i;
        }

        bool compare(size_t lhs, size_t rhs) {
            alias binaryFun!(compFun) innerComp;
            return innerComp(input[lhs], input[rhs]);
        }

        qsort!compare(indices);

        Ret[] ret;
        if(buf.length < indices.length) {
            ret = newVoid!Ret(indices.length);
        } else {
            ret = buf[0..indices.length];
        }

        foreach(i, index; indices) {
            ret[index] = i + 1;
        }

        auto myIndexed = Indexed!(T)(input, indices);
        averageTies(myIndexed, ret, indices);
        return ret;
    }
}

private struct Indexed(T) {
    T someRange;
    size_t[] indices;

    ElementType!T opIndex(size_t index) {
        return someRange[indices[index]];
    }

    size_t length() {
        return indices.length;
    }
}

/**Same as rank(), but also sorts the input range in ascending order.
 * The array returned will still be identical to that returned by rank(), i.e.
 * the rank of each element will correspond to the ranks of the elements in the
 * input array before sorting.
 *
 * Works with any random access range with a length property.
 *
 * Examples:
 * ---
 * uint[] test = [3, 5, 3, 1, 2];
 * assert(rank(test) == [3.5f, 5f, 3.5f, 1f, 2f]);
 * assert(test == [1U, 2, 3, 4, 5]);
 * ---*/
Ret[] rankSort(alias compFun = "a < b", Ret = float, T)(T input, Ret[] buf = null)
if(isRandomAccessRange!(T) && hasLength!(T)) {
    mixin(newFrame);
    Ret[] ranks;
    if(buf.length < input.length) {
        ranks = newVoid!(Ret)(input.length);
    } else {
        ranks = buf[0..input.length];
    }

    size_t[] perms = newStack!(size_t)(input.length);
    foreach(i, ref p; perms) {
        p = i;
    }

    qsort!compFun(input, perms);
    foreach(i; 0..perms.length)  {
        ranks[perms[i]] = i + 1;
    }
    averageTies(input, ranks, perms);
    return ranks;
}

unittest {
    uint[] test = [3, 5, 3, 1, 2];
    assert(rank(test) == [3.5f, 5f, 3.5f, 1f, 2f]);
    assert(test == [3U, 5, 3, 1, 2]);
    assert(rank!("a < b", double)(test) == [3.5, 5, 3.5, 1, 2]);
    assert(rankSort(test) == [3.5f, 5f, 3.5f, 1f, 2f]);
    assert(test == [1U,2,3,3,5]);
    writeln("Passed rank test.");
}

// Used internally by rank() and dstats.cor.scor().
void averageTies(T, U)(T sortedInput, U[] ranks, size_t[] perms)
in {
    assert(sortedInput.length == ranks.length);
    assert(ranks.length == perms.length);
} body {
    uint tieCount = 1, tieSum = cast(uint) ranks[perms[0]];
    foreach(i; 1..ranks.length) {
        if(sortedInput[i] == sortedInput[i - 1]) {
            tieCount++;
            tieSum += ranks[perms[i]];
        } else{
            if(tieCount > 1){
                real avg = cast(real) tieSum / tieCount;
                foreach(perm; perms[i - tieCount..i]) {
                    ranks[perm] = avg;
                }
                tieCount = 1;
            }
            tieSum = cast(uint) ranks[perms[i]];
        }
    }
    if(tieCount > 1) { // Handle the end.
        real avg = cast(real) tieSum / tieCount;
        foreach(perm; perms[perms.length - tieCount..$]) {
            ranks[perm] = avg;
        }
        tieCount = 1;
    }
}

/**Returns an AA of counts of every element in input.  Works w/ any iterable.
 *
 * Examples:
 * ---
 * int[] foo = [1,2,3,1,2,4];
 * uint[int] frq = frequency(foo);
 * assert(frq.length == 4);
 * assert(frq[1] == 2);
 * assert(frq[4] == 1);
 * ---*/
uint[IterType!(T)] frequency(T)(T input)
if(isIterable!(T)) {
    typeof(return) output;
    foreach(i; input) {
        output[i]++;
    }
    return output;
}

unittest {
    int[] foo = [1,2,3,1,2,4];
    uint[int] frq = frequency(foo);
    assert(frq.length == 4);
    assert(frq[1] == 2);
    assert(frq[4] == 1);
    writeln("Passed frequency test.");
}

///
T sign(T)(T num) pure nothrow {
    if (num > 0) return 1;
    if (num < 0) return -1;
    return 0;
}

unittest {
    assert(sign(3.14159265)==1);
    assert(sign(-3)==-1);
    assert(sign(-2.7182818)==-1);
    writefln("Passed sign unittest.");
}

///
/*Values up to 9,999 are pre-calculated and stored in
 * an immutable global array, for performance.  After this point, the gamma
 * function is used, because caching would take up too much memory, and if
 * done lazily, would cause threading issues.*/
real logFactorial(ulong n) {
    //Input is uint, can't be less than 0, no need to check.
    if(n < staticFacTableLen) {
        return staticLogFacTable[cast(size_t) n];
    } else return lgamma(cast(real) (n + 1));
}

unittest {
    // Cache branch.
    assert(cast(uint) round(exp(logFactorial(4)))==24);
    assert(cast(uint) round(exp(logFactorial(5)))==120);
    assert(cast(uint) round(exp(logFactorial(6)))==720);
    assert(cast(uint) round(exp(logFactorial(7)))==5040);
    assert(cast(uint) round(exp(logFactorial(3)))==6);
    // Gamma branch.
    assert(approxEqual(logFactorial(12000), 1.007175584216837e5, 1e-14));
    assert(approxEqual(logFactorial(14000), 1.196610688711534e5, 1e-14));
    writefln("Passed logFactorial unit test.");
}

///Log of (n choose k).
real logNcomb(ulong n, ulong k)
in {
    assert(k <= n);
} body {
    if(n < k) return -real.infinity;
    //Extra parentheses increase numerical accuracy.
    return logFactorial(n) - (logFactorial(k) + logFactorial(n-k));
}

unittest {
    assert(cast(uint) round(exp(logNcomb(4,2)))==6);
    assert(cast(uint) round(exp(logNcomb(30,8)))==5852925);
    assert(cast(uint) round(exp(logNcomb(28,5)))==98280);
    writefln("Passed logNcomb unit test.");
}

/**Controls whether Perm and Comb duplicate their buffer on each iteration and
 * return the copy, or recycle it and return an alias of it.
 * You want to choose RECYCLE if each permutation/combination
 * will only be needed within the scope of the foreach statement.  If they
 * may escape this scope, you want to choose DUP.  The default is DUP,
 * because it's safer, but RECYCLE can avoid lots of unnecessary GC activity.
 */
enum Buffer {

    ///
    DUP,

    ///
    RECYCLE
}

static if(size_t.sizeof == 4) {
    private enum MAX_PERM_LEN = 12;
} else {
    private enum MAX_PERM_LEN = 20;
}

/**A struct that generates all possible permutations of a sequence.  Due to
 * some optimizations done under the hood, this works as an input range if
 * T.sizeof > 1, or a forward range if T.sizeof == 1.
 *
 * Note:  Permutations are output in undefined order.
 *
 * Bugs:  Only supports iterating over up to size_t.max permutations.
 * This means the max permutation length is 12 on 32-bit machines, or 20
 * on 64-bit.  This was a conscious tradeoff to allow this range to have a
 * length of type size_t, since iterating over such huge permutation spaces
 * would be insanely slow anyhow.
 *
 * Examples:
 * ---
 *  double[][] res;
 *  auto perm = Perm!(double)([1.0, 2.0, 3.0][]);
 *  foreach(p; perm) {
 *      res ~= p;
 *  }
 *
 *  sort(res);
 *  assert(res.canFindSorted([1.0, 2.0, 3.0]));
 *  assert(res.canFindSorted([1.0, 3.0, 2.0]));
 *  assert(res.canFindSorted([2.0, 1.0, 3.0]));
 *  assert(res.canFindSorted([2.0, 3.0, 1.0]));
 *  assert(res.canFindSorted([3.0, 1.0, 2.0]));
 *  assert(res.canFindSorted([3.0, 2.0, 1.0]));
 *  assert(res.length == 6);
 *  ---
 */
struct Perm(Buffer bufType = Buffer.DUP, T) {
private:

    // Optimization:  Since we know this thing can't get too big (there's
    // an enforce statement for it in the c'tor), just use arrays of the max
    // possible size for stuff and store them inline, if it's all just bytes.
    static if(T.sizeof == 1) {
        T[MAX_PERM_LEN] perm;
    } else {
        T* perm;
    }

    // The length of this range.
    size_t nPerms;

    ubyte[MAX_PERM_LEN] Is;
    ubyte currentIndex;

    // The length of these arrays.  Stored once to minimize overhead.
    ubyte len;

    static if(bufType == Buffer.DUP) {
        alias T[] PermArray;
    } else {
        alias const(T)[] PermArray;
    }

public:
    /**Generate permutations from an input range.
     * Create a duplicate of this sequence
     * so that the original sequence is not modified.*/
    this(U)(U input)
    if(isForwardRange!(U)) {

        static if(ElementType!(U).sizeof > 1) {
            auto arr = toArray(input);
            enforce(arr.length <= MAX_PERM_LEN, text(
                "Can't iterate permutations of an array this long.  (Max length:  ",
                        MAX_PERM_LEN, ")"));
            len = cast(ubyte) arr.length;
            perm = arr.ptr;
        } else {
            foreach(elem; input) {
                enforce(len < MAX_PERM_LEN, text(
                    "Can't iterate permutations of an array this long.  (Max length:  ",
                        MAX_PERM_LEN, ")"));

                perm[len++] = elem;
            }
        }

        popFront();

        nPerms = 1;
        for(size_t i = 2; i <= len; i++) {
            nPerms *= i;
        }
    }

    /**Note:  PermArray is just an alias to either T[] or const(T)[],
     * depending on whether bufType == Buf.DUP or Buf.RECYCLE.
     */
    PermArray front() {
        static if(bufType == Buffer.DUP) {
            return perm[0..len].dup;
        } else {
            return perm[0..len];
        }
    }

    /**Get the next permutation in the sequence.*/
    void popFront() {
        if(len == 0) {
            nPerms--;
            return;
        }
        if(currentIndex == len - 1) {
            currentIndex--;
            nPerms--;
            return;
        }

        uint max = len - currentIndex;
        if(Is[currentIndex] == max) {

            if(currentIndex == 0) {
                nPerms--;
                assert(nPerms == 0, to!string(nPerms));
                return;
            }

            Is[currentIndex..len] = 0;
            currentIndex--;
            return popFront();
        } else {
            rotateLeft(perm[currentIndex..len]);
            Is[currentIndex]++;
            currentIndex++;
            return popFront();
        }
    }

    ///
    bool empty() {
        return nPerms == 0;
    }

    /**The number of permutations left.
     */
    size_t length() {
        return nPerms;
    }
}

private template PermRet(Buffer bufType, T...) {
    static if(isForwardRange!(T[0])) {
        alias Perm!(bufType, ElementType!(T[0])) PermRet;
    } else static if(T.length == 1) {
        alias Perm!(bufType, byte) PermRet;
    } else alias Perm!(bufType, T[0]) PermRet;
}

/**Create a Perm struct from a range or of a set of bounds.
 *
 * Note:  PermRet is just a template to figure out what this should return.
 * I would use auto if not for bug 2251.
 *
 * Examples:
 * ---
 * auto p = perm([1,2,3]);  // All permutations of [1,2,3].
 * auto p = perm(5);  // All permutations of [0,1,2,3,4].
 * auto p = perm(-1, 2); // All permutations of [-1, 0, 1].
 * ---
 */
PermRet!(bufType, T) perm(Buffer bufType = Buffer.DUP, T...)(T stuff) {
    alias typeof(return) rt;
    static if(isForwardRange!(T[0])) {
        return rt(stuff);
    } else static if(T.length == 1) {
        static assert(isIntegral!(T[0]),
            "If one argument is passed to perm(), it must be an integer.");

        enforce(stuff[0] <= MAX_PERM_LEN, text(
            "Can't iterate permutations of an array of length ",
            stuff[0], ".  (Max length:  ", MAX_PERM_LEN, ")"));

        // Optimization:  If we're duplicating the array every time we return
        // it, we want it to be as small as possible.  Since we know the lower
        // bound is zero and the upper bound can't be > byte.max, use bytes
        // instead of bigger integer types.
        return rt(seq(cast(byte) 0, cast(byte) stuff[0]));
    } else {
        static assert(stuff.length == 2);
        return rt(seq(stuff[0], stuff[1]));
    }
}

unittest {
    // Test degenerate case of len == 0;
    uint nZero = 0;
    foreach(elem; perm(0)) {
        assert(elem.length == 0);
        nZero++;
    }
    assert(nZero == 1);

    double[][] res;
    auto p1 = perm([1.0, 2.0, 3.0][]);
    assert(p1.length == 6);
    foreach(p; p1) {
        res ~= p;
    }
    sort(res);
    assert(res.canFindSorted([1.0, 2.0, 3.0]));
    assert(res.canFindSorted([1.0, 3.0, 2.0]));
    assert(res.canFindSorted([2.0, 1.0, 3.0]));
    assert(res.canFindSorted([2.0, 3.0, 1.0]));
    assert(res.canFindSorted([3.0, 1.0, 2.0]));
    assert(res.canFindSorted([3.0, 2.0, 1.0]));
    assert(res.length == 6);
    byte[][] res2;
    auto perm2 = perm(3);
    foreach(p; perm2) {
        res2 ~= p.dup;
    }
    sort(res2);
    assert(res2.canFindSorted([cast(byte) 0, 1, 2]));
    assert(res2.canFindSorted([cast(byte) 0u, 2, 1]));
    assert(res2.canFindSorted([cast(byte) 1u, 0, 2]));
    assert(res2.canFindSorted([cast(byte) 1u, 2, 0]));
    assert(res2.canFindSorted([cast(byte) 2u, 0, 1]));
    assert(res2.canFindSorted([cast(byte) 2u, 1, 0]));
    assert(res2.length == 6);

    // Indirect tests:  If the elements returned are unique, there are N! of
    // them, and they contain what they're supposed to contain, the result is
    // correct.
    auto perm3 = perm(0U, 6U);
    bool[uint[]] table;
    foreach(p; perm3) {
        table[p] = true;
    }
    assert(table.length == 720);
    foreach(elem, val; table) {
        assert(elem.dup.insertionSort == [0U, 1, 2, 3, 4, 5]);
    }
    auto perm4 = perm(5);
    bool[byte[]] table2;
    foreach(p; perm4) {
        table2[p] = true;
    }
    assert(table2.length == 120);
    foreach(elem, val; table2) {
        assert(elem.dup.insertionSort == [cast(byte) 0, 1, 2, 3, 4]);
    }
    writeln("Passed Perm test.");
}

/**Generates every possible combination of r elements of the given sequence, or r
 * array indices from zero to N, depending on which ctor is called.  Uses
 * an input range interface.
 *
 * Bugs:  Only supports iterating over up to size_t.max combinations.
 * This was a conscious tradeoff to allow this range to have a
 * length of type size_t, since iterating over such huge combination spaces
 * would be insanely slow anyhow.
 *
 * Examples:
 * ---
    auto comb1 = Comb!(uint)(5, 2);
    uint[][] vals;
    foreach(c; comb1) {
        vals ~= c;
    }
    sort(vals);
    assert(vals.canFindSorted([0u,1].dup));
    assert(vals.canFindSorted([0u,2].dup));
    assert(vals.canFindSorted([0u,3].dup));
    assert(vals.canFindSorted([0u,4].dup));
    assert(vals.canFindSorted([1u,2].dup));
    assert(vals.canFindSorted([1u,3].dup));
    assert(vals.canFindSorted([1u,4].dup));
    assert(vals.canFindSorted([2u,3].dup));
    assert(vals.canFindSorted([2u,4].dup));
    assert(vals.canFindSorted([3u,4].dup));
    assert(vals.length == 10);
    ---
 */
struct Comb(T, Buffer bufType = Buffer.DUP) {
private:
    int N;
    int R;
    int diff;
    uint* pos;
    T* myArray;
    T* chosen;
    size_t _length;

    static if(bufType == Buffer.DUP) {
        alias T[] CombArray;
    } else {
        alias const(T)[] CombArray;
    }

    void popFrontNum() {
        int index = R - 1;
        for(; index != -1 && pos[index] == diff + index; --index) {}
        if(index == -1) {
            _length--;
            return;
        }
        pos[index]++;
        for(size_t i = index + 1; i < R; ++i) {
            pos[i] = pos[index] + i - index;
        }
        _length--;
    }

    void popFrontArray() {
        int index = R - 1;
        for(; index != -1 && pos[index] == diff + index; --index) {}
        if(index == -1) {
            _length--;
            return;
        }
        pos[index]++;
        chosen[index] = myArray[pos[index]];
        for(size_t i = index + 1; i < R; ++i) {
            pos[i] = pos[index] + i - index;
            chosen[i] = myArray[pos[i]];
        }
        _length--;
    }

    void setLen() {
        // Used at construction.
        real rLen = exp( logNcomb(N, R));
        enforce(rLen < size_t.max, "Too many combinations.");
        _length = roundTo!size_t(rLen);
    }

public:

    /**Ctor to generate all possible combinations of array indices for a length r
     * array.  This is a special-case optimization and is faster than simply
     * using the other ctor to generate all length r combinations from
     * seq(0, length).*/
    static if(is(T == uint)) {
        this(uint n, uint r)
        in {
            assert(n >= r);
        } body {
            if(r > 0) {
                pos = (seq(0U, r)).ptr;
                pos[r - 1]--;
            }
            N = n;
            R = r;
            diff = N - R;
            popFront();
            setLen();
        }
    }

    /**General ctor.  array is a sequence from which to generate the
     * combinations.  r is the length of the combinations to be generated.*/
    this(T[] array, uint r) {
        if(r > 0) {
            pos = (seq(0U, r)).ptr;
            pos[r - 1]--;
        }
        N = array.length;
        R = r;
        diff = N - R;
        auto temp = array.dup;
        myArray = temp.ptr;
        chosen = (new T[r]).ptr;
        foreach(i; 0..r) {
            chosen[i] = myArray[pos[i]];
        }
        popFront();
        setLen();
    }

    CombArray front() {
        static if(bufType == Buffer.RECYCLE) {
            static if(!is(T == uint)) {
                return chosen[0..R].dup;
            } else {
                return (myArray is null) ? pos[0..R] : chosen[0..R];
            }
        } else {
            static if(!is(T == uint)) {
                return chosen[0..R].dup;
            } else {
                return (myArray is null) ? pos[0..R].dup : chosen[0..R].dup;
            }
        }
    }

    void popFront() {
        return (myArray is null) ? popFrontNum() : popFrontArray();
    }

    ///
    bool empty() {
        return length == 0;
    }

    ///
    size_t length() {
        return _length;
    }
}

private template CombRet(T, Buffer bufType) {
    static if(isForwardRange!(T)) {
        alias Comb!(Unqual!(ElementType!(T)), bufType) CombRet;
    } else static if(isIntegral!T) {
        alias Comb!(uint, bufType) CombRet;
    } else static assert(0, "comb can only be created with range or uint.");
}

/**Create a Comb struct from a range or of a set of bounds.
 *
 * Note:  CombRet is just a template to figure out what this should return.
 * I would use auto if not for bug 2251.
 *
 * Examples:
 * ---
 * auto c1 = comb([1,2,3], 2);  // Any two elements from [1,2,3].
 * auto c2 = comb(5, 3);  // Any three elements from [0,1,2,3,4].
 * ---
 */
CombRet!(T, bufType) comb(Buffer bufType = Buffer.DUP, T)(T stuff, uint r) {
    alias typeof(return) rt;
    static if(isForwardRange!(T)) {
        return rt(stuff, r);
    } else {
        static assert(isIntegral!T, "Can only call comb on ints and ranges.");
        return rt(cast(uint) stuff, r);
    }
}

unittest {
    // Test degenerate case of r == 0.  Shouldn't segfault.
    uint nZero = 0;
    foreach(elem; comb(5, 0)) {
        assert(elem.length == 0);
        nZero++;
    }
    assert(nZero == 1);

    nZero = 0;
    uint[] foo = [1,2,3,4,5];
    foreach(elem; comb(foo, 0)) {
        assert(elem.length == 0);
        nZero++;
    }
    assert(nZero == 1);

    // Test indexing verison first.
    auto comb1 = comb(5, 2);
    uint[][] vals;
    foreach(c; comb1) {
        vals ~= c;
    }

    sort(vals);
    assert(vals.canFindSorted([0u,1].dup));
    assert(vals.canFindSorted([0u,2].dup));
    assert(vals.canFindSorted([0u,3].dup));
    assert(vals.canFindSorted([0u,4].dup));
    assert(vals.canFindSorted([1u,2].dup));
    assert(vals.canFindSorted([1u,3].dup));
    assert(vals.canFindSorted([1u,4].dup));
    assert(vals.canFindSorted([2u,3].dup));
    assert(vals.canFindSorted([2u,4].dup));
    assert(vals.canFindSorted([3u,4].dup));
    assert(vals.length == 10);

    // Now, test the array version.
    auto comb2 = comb(seq(5U, 10U), 3);
    vals = null;
    foreach(c; comb2) {
        vals ~= c;
    }
    sort(vals);
    assert(vals.canFindSorted([5u, 6, 7].dup));
    assert(vals.canFindSorted([5u, 6, 8].dup));
    assert(vals.canFindSorted([5u, 6, 9].dup));
    assert(vals.canFindSorted([5u, 7, 8].dup));
    assert(vals.canFindSorted([5u, 7, 9].dup));
    assert(vals.canFindSorted([5u, 8, 9].dup));
    assert(vals.canFindSorted([6U, 7, 8].dup));
    assert(vals.canFindSorted([6u, 7, 9].dup));
    assert(vals.canFindSorted([6u, 8, 9].dup));
    assert(vals.canFindSorted([7u, 8, 9].dup));
    assert(vals.length == 10);

    // Now a test of a larger dataset where more subtle bugs could hide.
    // If the values returned are unique even after sorting, are composed of
    // the correct elements, and there is the right number of them, this thing
    // works.

    bool[uint[]] results;  // Keep track of how many UNIQUE items we have.
    auto comb3 = Comb!(uint)(seq(10U, 22U), 6);
    foreach(c; comb3) {
        auto dupped = c.dup.sort;
        // Make sure all elems are unique and within range.
        assert(dupped.length == 6);
        assert(dupped[0] > 9 && dupped[0] < 22);
        foreach(i; 1..dupped.length) {
            // Make sure elements are unique.  Remember, the array is sorted.
            assert(dupped[i] > dupped[i - 1]);
            assert(dupped[i] > 9 && dupped[i] < 22);
        }
        results[dupped] = true;
    }
    assert(results.length == 924);  // (12 choose 6).
    writeln("Passed Comb test.");
}

/**Converts a range with arbitrary element types (usually strings) to a
 * range of reals lazily.  Ignores any elements that could not be successfully
 * converted.  Useful for creating an input range that can be used with this
 * lib out of a File without having to read the whole file into an array first.
 * The advantages to this over just using std.algorithm.map are that it's
 * less typing and that it ignores non-convertible elements, such as blank
 * lines.
 *
 * If rangeIn is an inputRange, then the result of this function is an input
 * range.  Otherwise, the result is a forward range.
 *
 * Note:  The reason this struct doesn't have length or random access,
 * even if this is supported by rangeIn, is because it has to be able to
 * filter out non-convertible elements.
 *
 * Examples:
 * ---
 * // Perform a T-test to see whether the mean of the data being input as text
 * // from stdin is different from zero.  This data might not even fit in memory
 * // if it were read in eagerly.
 *
 * auto myRange = toNumericRange( stdin.byLine() );
 * TestRes result = studentsTTest(myRange);
 * writeln(result);
 * ---
 */
ToNumericRange!R toNumericRange(R)(R rangeIn) if(isInputRange!R) {
    alias ToNumericRange!R RT;
    return RT(rangeIn);
}

///
struct ToNumericRange(R) if(isInputRange!R) {
private:
    alias ElementType!R E;
    R inputRange;
    real _front;

public:
    this(R inputRange) {
        this.inputRange = inputRange;
        try {
            _front = to!real(inputRange.front);
        } catch(ConvError) {
            popFront();
        }
    }

    real front() {
        return _front;
    }

    void popFront() {
        while(true) {
            inputRange.popFront();
            if(inputRange.empty) {
                return;
            }
            auto inFront = inputRange.front;

            // If inFront is some string, strip the whitespace.
            static if( is(typeof(strip(inFront)))) {
                inFront = strip(inFront);
            }

            try {
                _front = to!real(inFront);
                return;
            } catch(ConvError) {
                continue;
            }
        }
    }

    bool empty() {
        return inputRange.empty;
    }
}

unittest {
    // Test both with non-convertible element as first element and without.
    // This is because non-convertible elements as the first element are
    // handled as a special case in the implementation.
    string[2] dataArr = ["3.14\n2.71\n8.67\nabracadabra\n362436",
                 "foobar\n3.14\n2.71\n8.67\nabracadabra\n362436"];

    foreach(data; dataArr) {
        std.file.write("NumericFileTestDeleteMe.txt", data);
        scope(exit) std.file.remove("NumericFileTestDeleteMe.txt");
        auto myFile = File("NumericFileTestDeleteMe.txt");
        auto rng = toNumericRange(myFile.byLine());
        assert(approxEqual(rng.front, 3.14));
        rng.popFront;
        assert(approxEqual(rng.front, 2.71));
        rng.popFront;
        assert(approxEqual(rng.front, 8.67));
        rng.popFront;
        assert(approxEqual(rng.front, 362435));
        assert(!rng.empty);
        rng.popFront;
        assert(rng.empty);
        myFile.close();
    }

    writeln("Passed toNumericRange unittest.");
}

// Verify that there are no TempAlloc memory leaks anywhere in the code covered
// by the unittest.  This should always be the last unittest of the module.
unittest {
    auto TAState = TempAlloc.getState;
    assert(TAState.used == 0);
    assert(TAState.nblocks < 2);
}
