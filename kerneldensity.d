/**This module contains a small but growing library for performing kernel
 * density estimation.
 *
 * Author:  David Simcha
 */
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
module dstats.kerneldensity;

import std.conv, std.math, std.algorithm, std.exception, std.traits, std.range,
    std.array, std.typetuple, dstats.distrib;

import  dstats.alloc, dstats.base, dstats.summary;

version(unittest) {

    import dstats.random, std.stdio;

    void main() {}
}

/**Estimates densities in the 1-dimensional case.  The 1-D case is special
 * enough to be treated as a special case, since it's very common and enables
 * some significant optimizations that are otherwise not feasible.
 *
 * Under the hood, this works by binning the data into a large number of bins
 * (currently 1,000), convolving it with the kernel function to smooth it, and
 * then using linear interpolation to evaluate the density estimates.  This
 * will produce results that are different from the textbook definition of
 * kernel density estimation, but to an extent that's negligible in most cases.
 * It also means that constructing this object is relatively expensive, but
 * evaluating a density estimate can be done in O(1) time complexity afterwords.
 */
class KernelDensity1D {
private:
    immutable double[] bins;
    immutable double[] cumulative;
    immutable double minElem;
    immutable double maxElem;
    immutable double diffNeg1Nbin;


    this(immutable double[] bins, immutable double[] cumulative,
         double minElem, double maxElem) {
        this.bins = bins;
        this.cumulative = cumulative;
        this.minElem = minElem;
        this.maxElem = maxElem;
        this.diffNeg1Nbin = bins.length / (maxElem - minElem);
    }

    private static double findEdgeBuffer(C)(C kernel) {
        // Search for the approx. point where the kernel's density is 0.001 *
        // what it is at zero.
        immutable zeroVal = kernel(0);
        double ret = 1;

        double factor = 4;
        double kernelVal;

        do {
            while(kernel(ret) / zeroVal > 1e-3) {
                ret *= factor;
            }

            factor = (factor - 1) / 2 + 1;
            while(kernel(ret) / zeroVal < 1e-4) {
                ret /= factor;
            }

            kernelVal = kernel(ret) / zeroVal;
        } while((kernelVal > 1e-3 || kernelVal < 1e-4) && factor > 1);

        return ret;
    }

public:
    /**Construct a kernel density estimation object from a callable object.
     * R must be a range of numeric types.  C must be a kernel function,
     * delegate, or class or struct with overloaded opCall.  The kernel
     * function is assumed to be symmetric about zero, to take its maximum
     * value at zero and to be unimodal.
     *
     * edgeBuffer determines how much space below and above the smallest and
     * largest observed value will be allocated when doing the binning.
     * Values less than reduce!min(range) - edgeBuffer or greater than
     * reduce!max(range) + edgeBuffer will be assigned a density of zero.
     * If this value is left at its default, it will be set to a value at which
     * the kernel is somewhere between 1e-3 and 1e-4 times its value at zero.
     *
     * The bandwidth of the kernel is indirectly selected by parametrizing the
     * kernel function.
     *
     * Examples:
     * ---
     * auto randNums = randArray!rNorm(1_000, 0, 1);
     * auto kernel = parametrize!normalPDF(0, 0.01);
     * auto density = KernelDensity1D(kernel, randNums);
     * writeln(normalPDF(1, 0, 1), "  ", density(1)).  // Should be about the same.
     * ---
     */
    static KernelDensity1D fromCallable(C, R)
    (scope C kernel, R range, double edgeBuffer = double.nan)
    if(isForwardRange!R && is(typeof(kernel(2.0)) : double)) {
        enum nBin = 1000;
        mixin(newFrame);

        uint N = 0;
        double minElem = double.infinity;
        double maxElem = -double.infinity;
        foreach(elem; range) {
            minElem = min(minElem, elem);
            maxElem = max(maxElem, elem);
            N++;
        }

        if(isNaN(edgeBuffer)) {
            edgeBuffer = findEdgeBuffer(kernel);
        }
        minElem -= edgeBuffer;
        maxElem += edgeBuffer;

        // Using ints here because they convert faster to floats than uints do.
        auto binsRaw = newStack!int(nBin);
        binsRaw[] = 0;

        foreach(elemRaw; range) {
            double elem = elemRaw - minElem;
            elem /= (maxElem - minElem);
            elem *= nBin;
            auto bin = to!uint(elem);
            if(bin == nBin) {
                bin--;
            }

            binsRaw[bin]++;
        }

        // Convolve the binned data with our kernel.  Since N is fairly small
        // we'll use a simple O(N^2) algorithm.  According to my measurements,
        // this is actually comparable in speed to using an FFT (and a lot
        // simplier and more space efficient) because:
        //
        // 1.  We can take advantage of kernel symmetry.
        //
        // 2.  We can take advantage of the sparsity of binsRaw.  (We don't
        //     need to convolve the zero count bins.)
        //
        // 3.  We don't need to do any zero padding to get a non-cyclic
        //     convolution.
        //
        // 4.  We don't need to convolve the tails of the kernel function,
        //     where the contribution to the final density estimate would be
        //     negligible.
        auto binsCooked = newVoid!double(nBin);
        binsCooked[] = 0;

        auto kernelPoints = newStack!double(nBin);
        immutable stepSize = (maxElem - minElem) / nBin;

        kernelPoints[0] = kernel(0);
        immutable stopAt = kernelPoints[0] * 1e-10;
        foreach(ptrdiff_t i; 1..kernelPoints.length) {
            kernelPoints[i] = kernel(stepSize * i);

            // Don't bother convolving stuff that contributes negligibly.
            if(kernelPoints[i] < stopAt) {
                kernelPoints = kernelPoints[0..i];
                break;
            }
        }

        foreach(i, count; binsRaw) if(count > 0) {
            binsCooked[i] += kernelPoints[0] * count;

            foreach(offset; 1..min(kernelPoints.length, max(i + 1, nBin - i))) {
                immutable kernelVal = kernelPoints[offset];

                if(i >= offset) {
                    binsCooked[i - offset] += kernelVal * count;
                }

                if(i + offset < nBin) {
                    binsCooked[i + offset] += kernelVal * count;
                }
            }
        }

        binsCooked[] /= sum(binsCooked);
        binsCooked[] *= nBin / (maxElem - minElem);  // Make it a density.

        auto cumulative = newVoid!double(nBin);
        cumulative[0] = binsCooked[0];
        foreach(i; 1..nBin) {
            cumulative[i] = cumulative[i - 1] + binsCooked[i];
        }
        cumulative[] /= cumulative[$ - 1];

        return new typeof(this)(
            assumeUnique(binsCooked), assumeUnique(cumulative),
            minElem, maxElem);
    }

    /**Construct a kernel density estimator from an alias.*/
    static KernelDensity1D fromAlias(alias kernel, R)
    (R range, double edgeBuffer = double.nan)
    if(isForwardRange!R && is(typeof(kernel(2.0)) : double)) {
        static double kernelFun(double x) {
            return kernel(x);
        }

        return fromCallable(&kernelFun, range, edgeBuffer);
    }

    /**Construct a kernel density estimator using the default kernel, which is
     * a Gaussian kernel with the Scott bandwidth.
     */
    static KernelDensity1D fromDefaultKernel(R)
    (R range, double edgeBuffer = double.nan)
    if(isForwardRange!R && is(ElementType!R : double)) {
        immutable bandwidth = scottBandwidth(range.save);

        double kernel(double x) {
            return normalPDF(x, 0, bandwidth);
        }

        return fromCallable(&kernel, range, edgeBuffer);
    }

    /**Compute the probability density at a given point.*/
    double opCall(double x) const {
        if(x < minElem || x > maxElem) {
            return 0;
        }

        x -= minElem;
        x *= diffNeg1Nbin;

        immutable fract = x - floor(x);
        immutable upper = to!size_t(ceil(x));
        immutable lower = to!size_t(floor(x));

        if(upper == bins.length) {
            return bins[$ - 1];
        }

        immutable ret = fract * bins[upper] + (1 - fract) * bins[lower];
        return max(0, ret);  // Compensate for roundoff
    }

    /**Compute the cumulative density, i.e. the integral from -infinity to x.*/
    double cdf(double x) const {
        if(x <= minElem) {
            return 0;
        } else if(x >= maxElem) {
            return 1;
        }

        x -= minElem;
        x *= diffNeg1Nbin;

        immutable fract = x - floor(x);
        immutable upper = to!size_t(ceil(x));
        immutable lower = to!size_t(floor(x));

        if(upper == cumulative.length) {
            return 1;
        }

        return fract * cumulative[upper] + (1 - fract) * cumulative[lower];
    }

    /**Compute the cumulative density from the rhs, i.e. the integral from
     * x to infinity.
     */
    double cdfr(double x) const {
        // Here, we can get away with just returning 1 - cdf b/c
        // there are inaccuracies several orders of magnitude bigger than
        // the rounding error.
        return 1.0 - cdf(x);
    }
}

unittest {
    auto kde = KernelDensity1D.fromCallable(parametrize!normalPDF(0, 1), [0]);
    assert(approxEqual(kde(1), normalPDF(1)));
    assert(approxEqual(kde.cdf(1), normalCDF(1)));
    assert(approxEqual(kde.cdfr(1), normalCDFR(1)));

    // This is purely to see if fromAlias works.
    auto cosKde = KernelDensity1D.fromAlias!cos([0], 1);

    // Make sure fromDefaultKernel at least instantiates.
    auto defaultKde = KernelDensity1D.fromDefaultKernel([1, 2, 3]);
}

/**Uses Scott's Rule to select the bandwidth of the Gaussian kernel density
 * estimator.  This is 1.06 * min(stdev(data), interquartileRange(data) / 1.34)
 * N ^^ -0.2.  R must be a forward range of numeric types.
 *
 * Examples:
 * ---
 * immutable bandwidth = scottBandwidth(data);
 * auto kernel = parametrize!normalPDF(0, bandwidth);
 * auto kde = KernelDensity1D(data, kernel);
 * ---
 *
 * References:
 * Scott, D. W. (1992) Multivariate Density Estimation: Theory, Practice,
 * and Visualization. Wiley.
 */
double scottBandwidth(R)(R data)
if(isForwardRange!R && is(ElementType!R : double)) {

    immutable summary = meanStdev(data.save);
    immutable interquartile = interquantileRange(data.save, 0.25) / 1.34;
    immutable sigmaHat = min(summary.stdev, interquartile);

    return 1.06 * sigmaHat * (summary.N ^^ -0.2);
}

unittest {
    // Values from R.
    assert(approxEqual(scottBandwidth([1,2,3,4,5]), 1.14666));
    assert(approxEqual(scottBandwidth([1,2,2,2,2,8,8,8,8]), 2.242446));
}

/**Construct an N-dimensional kernel density estimator.  This is done using
 * the textbook definition of kernel density estimation, since the binning
 * and convolving method used in the 1-D case would rapidly become
 * unfeasible w.r.t. memory usage as dimensionality increased.
 *
 * Eventually, a 2-D estimator might be added as another special case, but
 * beyond 2-D, bin-and-convolute clearly isn't feasible.
 *
 * This class can be used for 1-D estimation instead of KernelDensity1D, and
 * will work properly.  This is useful if:
 *
 * 1.  You can't accept even the slightest deviation from the results that the
 *     textbook definition of kernel density estimation would produce.
 *
 * 2.  You are only going to evaluate at a few points and want to avoid the
 *     up-front cost of the convolution used in the 1-D case.
 *
 * 3.  You're using some weird kernel that doesn't meet the assumptions
 *     required for KernelDensity1D.
 */
class KernelDensity {
    private immutable double[][] points;
    private double delegate(double[]...) kernel;

    private this(immutable double[][] points) {
        this.points = points;
    }

    /**Returns the number of dimensions in the estimator.*/
    uint nDimensions() const @property {
        // More than uint.max dimensions is absolutely implausible.
        assert(points.length <= uint.max);
        return cast(uint) points.length;
    }

    /**Construct a kernel density estimator from a kernel provided as a callable
     * object (such as a function pointer, delegate, or class with overloaded
     * opCall).  R must be either a range of ranges, multiple ranges passed in
     * as variadic arguments, or a single range for the 1D case.  Each range
     * represents the values of one variable in the joint distribution.
     * kernel must accept either an array of doubles or the same number of
     * arguments as the number of dimensions, and must return a floating point
     * number.
     *
     * Examples:
     * ---
     * // Create an estimate of the density of the joint distribution of
     * // hours sleep and programming skill.
     * auto programmingSkill = [8,6,7,5,3,0,9];
     * auto hoursSleep = [3,6,2,4,3,5,8];
     *
     * // Make a 2D Gaussian kernel function with bandwidth 0.5 in both
     * // dimensions and covariance zero.
     * static double myKernel(double x1, double x2) {
     *    return normalPDF(x1, 0, 0.5) * normalPDF(x2, 0, 0.5);
     * }
     *
     * auto estimator = KernelDensity.fromCallable
     *     (&myKernel, programmingSkill, hoursSleep);
     *
     * // Estimate the density at programming skill 1, 2 hours sleep.
     * auto density = estimator(1, 2);
     * ---
     */
    static KernelDensity fromCallable(C, R...)(C kernel, R ranges)
    if(allSatisfy!(isInputRange, R)) {
        auto kernelWrapped = wrapToArrayVariadic(kernel);

        static if(R.length == 1 && isInputRange!(typeof(ranges[0].front))) {
            alias ranges[0] data;
        } else {
            alias ranges data;
        }

        double[][] points;
        foreach(range; data) {
            double[] asDoubles;

            static if(dstats.base.hasLength!(typeof(range))) {
                asDoubles = newVoid!double(range.length);

                size_t i = 0;
                foreach(elem; range) {
                    asDoubles[i++] = elem;
                }
            } else {
                auto app = appender(&asDoubles);
                foreach(elem; range) {
                    app.put(elem);
                }
            }

            points ~= asDoubles;
        }

        dstatsEnforce(points.length,
            "Can't construct a zero dimensional kernel density estimator.");

        foreach(arr; points[1..$]) {
            dstatsEnforce(arr.length == points[0].length,
                "All ranges must be the same length to construct a KernelDensity.");
        }

        auto ret = new KernelDensity(assumeUnique(points));
        ret.kernel = kernelWrapped;

        return ret;
    }

    /**Estimate the density at the point given by x.  The variables in X are
     * provided in the same order as the ranges were provided for estimation.
     */
    double opCall(double[] x...) const {
        dstatsEnforce(x.length == points.length,
            "Dimension mismatch when evaluating kernel density.");
        double sum = 0;

        mixin(newFrame);
        auto dataPoint = newStack!double(points.length);
        foreach(i; 0..points[0].length) {
            foreach(j; 0..points.length) {
                dataPoint[j] = x[j] - points[j][i];
            }

            sum += kernel(dataPoint);
        }

        sum /= points[0].length;
        return sum;
    }
}

unittest {
    auto data = randArray!rNorm(100, 0, 1);
    auto kernel = parametrize!normalPDF(0, scottBandwidth(data));
    auto kde = KernelDensity.fromCallable(kernel, data);
    auto kde1 = KernelDensity1D.fromCallable(kernel, data);
    foreach(i; 0..5) {
        assert(abs(kde(i) - kde1(i)) < 0.01);
    }

    // Make sure example compiles.
    auto programmingSkill = [8,6,7,5,3,0,9];
    auto hoursSleep = [3,6,2,4,3,5,8];

    // Make a 2D Gaussian kernel function with bandwidth 0.5 in both
    // dimensions and covariance zero.
    static double myKernel(double x1, double x2) {
        return normalPDF(x1, 0, 0.5) * normalPDF(x2, 0, 0.5);
    }

    auto estimator = KernelDensity.fromCallable
        (&myKernel, programmingSkill, hoursSleep);

    // Estimate the density at programming skill 1, 2 hours sleep.
    auto density = estimator(1, 2);

    // Test instantiating from functor.
    auto foo = KernelDensity.fromCallable(estimator, hoursSleep);
}


private:

double delegate(double[]...) wrapToArrayVariadic(C)(C callable) {
    static if(is(C == delegate) || isFunctionPointer!C) {
        alias callable fun;
    } else {  // It's a functor.
        alias callable.opCall fun;
    }

    alias ParameterTypeTuple!fun params;
    static if(params.length == 1 && is(params[0] == double[])) {
        // Already in the right form.
        static if(is(C == delegate) && is(ReturnType!C == double)) {
            return callable;
        } else static if(is(ReturnType!(callable.opCall) == double)) {
            return &callable.opCall;
        } else {  // Need to forward.
            double forward(double[] args...) {
                return fun(args);
            }

            return &forward;
        }
    } else {  // Need to convert to single arguments and forward.
        static assert(allSatisfy!(isFloatingPoint, params));

        double doCall(double[] args...) {
            assert(args.length == params.length);
            mixin("return fun(" ~ makeCallList(params.length) ~ ");");
        }

        return &doCall;
    }
}

// CTFE function for forwarding elements of an array as single function
// arguments.
string makeCallList(uint N) {
    string ret;
    foreach(i; 0..N - 1) {
        ret ~= "args[" ~ to!string(i) ~ "], ";
    }

    ret ~= "args[" ~ to!string(N - 1) ~ "]";
    return ret;
}
