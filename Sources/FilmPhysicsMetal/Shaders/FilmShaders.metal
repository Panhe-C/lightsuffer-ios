//
//  FilmShaders.metal
//  light suffer胶片 — iOS app
//
//  The Metal compute kernels of the film simulation.
//
//  The kernels implement the very same computation as the pure Swift plan
//  evaluator of `FilmPhysics` (`FilmPlanEvaluator`), on the very same
//  numbers: the plan of the render is uploaded into the buffers below and
//  every kernel reads it.
//
//  The pipeline of a render:
//
//    rgb_in ──▶ raw ──▶ log_e_film ──▶ cmy_film ──▶ log_e_print ──▶ cmy_print ──▶ rgb_out
//
//  The spatial effects (the diffusion filters, the lens blurs, the
//  halation, the diffusion of the DIR couplers and the unsharp mask) are
//  the separable and the two dimensional convolutions of the pass chain.
//
//  film modeling powered by spektrafilm
//  https://github.com/andreavolpato/spektrafilm
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

#include <metal_stdlib>

using namespace metal;

#define FILM_PI 3.141592653589793
// The number of threads of the two stage maximum reduction.
#define FILM_REDUCE_THREADS 1024
// The maximum radius of a convolution kernel, in pixels.
//
// The radius is the truncation of the Gaussian at three sigmas: the bound
// makes the loops of the convolutions **bounded**, whatever the parameters
// of the render are (a radius of billions of pixels would make a kernel
// run for hours).  The Swift side uses the same bound
// (`MetalKernels.maxBlurRadius`).
#define FILM_MAX_BLUR_RADIUS 1024

// MARK: - The parameters of the plan

/// The parameters of a render.
///
/// The layout is mirrored **exactly** by the `FilmPlanParams` structure of
/// the Swift side (`MetalPlan.swift`): every member is four bytes wide, so
/// the two structures have the same size and the same offsets.
struct FilmPlanParams {
    uint width;
    uint height;
    uint tcLUTSize;
    uint wavelengthCount;
    uint filmCurveCount;
    uint printCurveCount;
    uint cMaxLightnessCount;
    uint cMaxHueCount;
    float filmCurveStart;
    float filmCurveStep;
    float filmCurveBeforeStart;
    float filmCurveBeforeStep;
    float printCurveStart;
    float printCurveStep;
    float exposureScale;
    float filmingScale;
    float couplerActive;
    float couplerPositive;
    float exposureFactor;
    float printExposure;
    float printingCorrection;
    float scanNormalization;
    float gamutActive;
    float lightnessActive;
    float gamutKneeThreshold;
    float gamutKneeLimit;
    float gamutKneePower;
    float lightnessKneeThreshold;
    float lightnessKneeLimit;
    float lightnessKneePower;
    float cam16LA;
    float cam16Yb;
    float cam16WhiteJp;
    float whiteX;
    float whiteY;
    float whiteZ;
    float correctionSlope;
    float correctionOffset;
    float correctionActive;
    float inputCCTF;
    float outputEncoded;
    float cMaxLightnessStart;
    float cMaxLightnessStep;
    float cMaxHueStart;
    float cMaxHueStep;
    float boostEV;
    float boostRange;
    float protectEV;
};

/// The parameters of the convolutions.
struct FilmBlurParams {
    uint width;
    uint height;
    uint radius;
    uint reserved;
    float weightA;
    float weightB;
    float weightC;
    float scatterFraction;
    // The Young & van Vliet recursion of the large sigmas: the flag of
    // every channel (one when the channel uses the recursion, zero when it
    // uses the truncated FIR kernel) and the four coefficients of the
    // recursion (`b`, `b1`, `b2` and `b3`).
    float iirFlagA;
    float iirB0A;
    float iirB1A;
    float iirB2A;
    float iirB3A;
    float iirFlagB;
    float iirB0B;
    float iirB1B;
    float iirB2B;
    float iirB3B;
    float iirFlagC;
    float iirB0C;
    float iirB1C;
    float iirB2C;
    float iirB3C;
};

/// The parameters of the linear combinations.
struct FilmCombineParams {
    uint width;
    uint height;
    float weightA;
    float weightB;
    float weightC;
    float weightD;
};

/// The parameters of the exposure (the linear to log10 conversion).
struct FilmExposureParams {
    uint width;
    uint height;
    float scale;
    float offset;
};

/// The parameters of the grain of the negative.
struct FilmGrainParams {
    uint width;
    uint height;
    uint sampleCount;
    uint layerCount;
    uint positive;
    // The sampler of the variates of the particles: zero for the fast
    // kernels of the upstream (the default), one for the exact samplers
    // (the inversion of the cumulative distribution, around the mode of the
    // distribution).  (`sampler` is a keyword of the shading language, so
    // the member is named `samplerMode`.)
    uint samplerMode;
};

/// The parameters of the micro structure of the emulsion.
struct FilmGrainClumpingParams {
    uint width;
    uint height;
    uint seed;
    float sigma;
};

/// The parameters of the glare of the print.
struct FilmGlareParams {
    uint width;
    uint height;
    uint seed;
    float mean;
    float std;
    float reserved;
};

// MARK: - The helpers

/// The decoding of an input value (0: none, 1: sRGB, 2: ProPhoto RGB).
inline float filmDecodeInput(float value, int cctf) {
    if (cctf == 1) {
        if (value <= 0.04045) {
            return value / 12.92;
        }
        return pow((value + 0.055) / 1.055, 2.4);
    }
    if (cctf == 2) {
        const float threshold = 16.0 * pow(16.0, 1.8 / (1.0 - 1.8));
        if (value < threshold) {
            return value / 16.0;
        }
        const float magnitude = pow(abs(value), 1.8);
        return value < 0.0 ? -magnitude : magnitude;
    }
    return value;
}

/// The sRGB encoding of a linear value.
inline float filmSRGBEncode(float value) {
    if (value <= 0.0031308) {
        return 12.92 * value;
    }
    return 1.055 * pow(value, 1.0 / 2.4) - 0.055;
}

/// The Mitchell-Netravali cubic kernel weight (B = C = 1/3).
inline float filmMitchellWeight(float t) {
    const float x = abs(t);
    const float b = 1.0 / 3.0;
    const float c = 1.0 / 3.0;
    if (x < 1.0) {
        return (1.0 / 6.0) * (
            (12.0 - 9.0 * b - 6.0 * c) * x * x * x
            + (-18.0 + 12.0 * b + 6.0 * c) * x * x
            + (6.0 - 2.0 * b)
        );
    }
    if (x < 2.0) {
        return (1.0 / 6.0) * (
            (-b - 6.0 * c) * x * x * x
            + (6.0 * b + 30.0 * c) * x * x
            + (-12.0 * b - 48.0 * c) * x
            + (8.0 * b + 24.0 * c)
        );
    }
    return 0.0;
}

/// The reflected index of the cubic interpolation (the upstream `safe_index`).
inline int filmSafeIndex(int index, int length) {
    if (index < 0) {
        return -index;
    }
    if (index >= length) {
        return 2 * (length - 1) - index;
    }
    return index;
}

/// The `reflect` boundary of the Gaussian filter of the upstream
/// (SciPy's `reflect` mode: the edge sample is repeated).
inline int filmReflectEdge(int index, int count) {
    if (count <= 0) {
        return 0;
    }
    const int period = 2 * count;
    int folded = index % period;
    if (folded < 0) {
        folded += period;
    }
    if (folded < count) {
        return folded;
    }
    return period - 1 - folded;
}

/// The `numpy.pad(..., mode="reflect")` boundary of the diffusion filter
/// (the half sample symmetric reflection).
inline int filmNumpyReflect(int index, int count) {
    if (count <= 1) {
        return 0;
    }
    const int period = 2 * (count - 1);
    int folded = index % period;
    if (folded < 0) {
        folded += period;
    }
    if (folded >= count) {
        folded = period - folded;
    }
    return folded;
}

/// The cubic lookup of the hanatos 2025 table.
inline float3 filmTCLookup(
    device const float *lut,
    uint size,
    float u,
    float v
) {
    if (size < 2) {
        return float3(0.0);
    }
    const float maxIndex = float(size - 1);
    const float cu = clamp(u, 0.0, 1.0) * maxIndex;
    const float cv = clamp(v, 0.0, 1.0) * maxIndex;

    uint uBase = 0;
    float uFraction = 0.0;
    if (cu >= maxIndex) {
        uBase = size - 2;
        uFraction = 1.0;
    } else {
        uBase = uint(floor(cu));
        uFraction = cu - float(uBase);
    }
    uint vBase = 0;
    float vFraction = 0.0;
    if (cv >= maxIndex) {
        vBase = size - 2;
        vFraction = 1.0;
    } else {
        vBase = uint(floor(cv));
        vFraction = cv - float(vBase);
    }

    float weightsU[4];
    float weightsV[4];
    weightsU[0] = filmMitchellWeight(uFraction + 1.0);
    weightsU[1] = filmMitchellWeight(uFraction);
    weightsU[2] = filmMitchellWeight(uFraction - 1.0);
    weightsU[3] = filmMitchellWeight(uFraction - 2.0);
    weightsV[0] = filmMitchellWeight(vFraction + 1.0);
    weightsV[1] = filmMitchellWeight(vFraction);
    weightsV[2] = filmMitchellWeight(vFraction - 1.0);
    weightsV[3] = filmMitchellWeight(vFraction - 2.0);

    float r = 0.0;
    float g = 0.0;
    float b = 0.0;
    float weightSum = 0.0;
    for (int i = 0; i < 4; ++i) {
        const int ui = filmSafeIndex(int(uBase) - 1 + i, int(size));
        for (int j = 0; j < 4; ++j) {
            const int vj = filmSafeIndex(int(vBase) - 1 + j, int(size));
            const float weight = weightsU[i] * weightsV[j];
            weightSum += weight;
            const uint index = (uint(ui) * size + uint(vj)) * 3;
            r += weight * lut[index];
            g += weight * lut[index + 1];
            b += weight * lut[index + 2];
        }
    }
    if (weightSum != 0.0) {
        r /= weightSum;
        g /= weightSum;
        b /= weightSum;
    }
    return float3(r, g, b);
}

/// The evaluation of a characteristic curve on its uniform log exposure grid.
inline float filmSampleCurve(
    device const float *curve,
    uint count,
    float start,
    float step,
    float x,
    uint channel
) {
    if (count == 0) {
        return 0.0;
    }
    if (isnan(x)) {
        return curve[channel * count];
    }
    if (x <= start) {
        return curve[channel * count];
    }
    const float last = start + step * float(count - 1);
    if (x >= last) {
        return curve[channel * count + count - 1];
    }
    const float position = (x - start) / step;
    int index = int(floor(position));
    if (index < 0) {
        index = 0;
    }
    if (index > int(count) - 2) {
        index = int(count) - 2;
    }
    const float fraction = position - float(index);
    const float low = curve[channel * count + uint(index)];
    const float high = curve[channel * count + uint(index) + 1];
    return low + fraction * (high - low);
}

// MARK: - The CAM16 colour appearance model

/// The signed power `spow(x, p) = sign(x) · |x| ** p`.
inline float filmSpow(float x, float p) {
    const float magnitude = pow(abs(x), p);
    return x < 0.0 ? -magnitude : magnitude;
}

/// The luminance level adaptation factor `F_L`.
inline float filmLuminanceLevelAdaptationFactor(float LA) {
    const float k = 1.0 / (5.0 * LA + 1.0);
    const float k4 = pow(k, 4.0);
    return 0.2 * k4 * (5.0 * LA)
        + 0.1 * pow(1.0 - k4, 2.0) * filmSpow(5.0 * LA, 1.0 / 3.0);
}

/// The forward post-adaptation non-linear response compression.
inline float3 filmResponseCompressionForward(float3 rgb, float FL) {
    const float cx = filmSpow(FL * abs(rgb.x) / 100.0, 0.42);
    const float cy = filmSpow(FL * abs(rgb.y) / 100.0, 0.42);
    const float cz = filmSpow(FL * abs(rgb.z) / 100.0, 0.42);
    const float rx = (400.0 * (rgb.x < 0.0 ? -1.0 : 1.0) * cx) / (27.13 + cx) + 0.1;
    const float ry = (400.0 * (rgb.y < 0.0 ? -1.0 : 1.0) * cy) / (27.13 + cy) + 0.1;
    const float rz = (400.0 * (rgb.z < 0.0 ? -1.0 : 1.0) * cz) / (27.13 + cz) + 0.1;
    return float3(rx, ry, rz);
}

/// The inverse post-adaptation non-linear response compression.
inline float3 filmResponseCompressionInverse(float3 rgb, float FL) {
    float rx = 0.0;
    float ry = 0.0;
    float rz = 0.0;
    const float ax = abs(rgb.x - 0.1);
    const float ay = abs(rgb.y - 0.1);
    const float az = abs(rgb.z - 0.1);
    rx = (rgb.x - 0.1 < 0.0 ? -1.0 : 1.0) * 100.0 / FL
        * filmSpow((27.13 * ax) / (400.0 - ax), 1.0 / 0.42);
    ry = (rgb.y - 0.1 < 0.0 ? -1.0 : 1.0) * 100.0 / FL
        * filmSpow((27.13 * ay) / (400.0 - ay), 1.0 / 0.42);
    rz = (rgb.z - 0.1 < 0.0 ? -1.0 : 1.0) * 100.0 / FL
        * filmSpow((27.13 * az) / (400.0 - az), 1.0 / 0.42);
    return float3(rx, ry, rz);
}

/// The achromatic response.
inline float filmAchromaticResponse(float3 rgb, float Nbb) {
    return (2.0 * rgb.x + rgb.y + (1.0 / 20.0) * rgb.z - 0.305) * Nbb;
}

/// The hue angle, in degrees.
inline float filmHueAngle(float a, float b) {
    float angle = atan2(b, a) * (180.0 / FILM_PI);
    angle = fmod(angle, 360.0);
    if (angle < 0.0) {
        angle += 360.0;
    }
    return angle;
}

/// The eccentricity factor.
inline float filmEccentricityFactor(float h) {
    return 0.25 * (cos(2.0 + h * FILM_PI / 180.0) + 3.8);
}

/// The multiplication of the CAT16 cone response matrix with a vector.
inline float3 filmCAM16ConeResponse(float3 xyz) {
    return float3(
        0.401288 * xyz.x + 0.650173 * xyz.y - 0.051461 * xyz.z,
        -0.250268 * xyz.x + 1.204414 * xyz.y + 0.045854 * xyz.z,
        -0.002079 * xyz.x + 0.048952 * xyz.y + 0.953127 * xyz.z
    );
}

/// The multiplication of the inverse CAT16 cone response matrix with a
/// vector.
inline float3 filmCAM16InverseConeResponse(float3 rgb) {
    return float3(
        1.86206786 * rgb.x - 1.01125463 * rgb.y + 0.14918678 * rgb.z,
        0.38752654 * rgb.x + 0.62144744 * rgb.y - 0.00897399 * rgb.z,
        -0.01584150 * rgb.x - 0.03412294 * rgb.y + 1.04996444 * rgb.z
    );
}

/// The CAM16 correlates of an XYZ triplet (the scale 100 domain).
///
/// The returns are `J`, `C`, `M` (the colourfulness) and the hue angle `h`
/// (in degrees).
inline float4 filmCAM16Forward(
    float3 xyz,
    float3 xyzWhite,
    float LA,
    float Yb
) {
    const float Yw = xyzWhite.y;
    const float3 rgbWhite = filmCAM16ConeResponse(xyzWhite);

    const float D = clamp(
        1.0 * (1.0 - (1.0 / 3.6) * exp((-LA - 42.0) / 92.0)),
        0.0,
        1.0
    );
    const float n = Yb / Yw;
    const float FL = filmLuminanceLevelAdaptationFactor(LA);
    const float Nbb = 0.725 * pow(1.0 / n, 0.2);
    const float Ncb = Nbb;
    const float z = 1.48 + sqrt(n);

    const float3 dRGB = float3(
        D * Yw / rgbWhite.x + 1.0 - D,
        D * Yw / rgbWhite.y + 1.0 - D,
        D * Yw / rgbWhite.z + 1.0 - D
    );
    const float3 rgbWhiteCompressed = filmResponseCompressionForward(dRGB * rgbWhite, FL);
    const float aw = filmAchromaticResponse(rgbWhiteCompressed, Nbb);

    const float3 rgb = filmCAM16ConeResponse(xyz);
    const float3 rgbCompressed = filmResponseCompressionForward(dRGB * rgb, FL);

    const float a = rgbCompressed.x - 12.0 * rgbCompressed.y / 11.0 + rgbCompressed.z / 11.0;
    const float b = (rgbCompressed.x + rgbCompressed.y - 2.0 * rgbCompressed.z) / 9.0;
    const float h = filmHueAngle(a, b);
    const float et = filmEccentricityFactor(h);
    const float A = filmAchromaticResponse(rgbCompressed, Nbb);

    const float J = 100.0 * filmSpow(A / aw, 0.69 * z);
    const float t = ((50000.0 / 13.0) * 1.0 * Ncb)
        * (et * sqrt(a * a + b * b)
            / (rgbCompressed.x + rgbCompressed.y + 21.0 * rgbCompressed.z / 20.0));
    const float C = filmSpow(t, 0.9) * filmSpow(J / 100.0, 0.5)
        * filmSpow(1.64 - pow(0.29, n), 0.73);
    const float M = C * filmSpow(FL, 0.25);

    return float4(J, C, M, h);
}

/// The XYZ tristimulus values of a CAM16 specification (the scale 100
/// domain).
inline float3 filmCAM16Inverse(
    float J,
    float C,
    float h,
    float3 xyzWhite,
    float LA,
    float Yb
) {
    const float Yw = xyzWhite.y;
    const float3 rgbWhite = filmCAM16ConeResponse(xyzWhite);

    const float D = clamp(
        1.0 * (1.0 - (1.0 / 3.6) * exp((-LA - 42.0) / 92.0)),
        0.0,
        1.0
    );
    const float n = Yb / Yw;
    const float FL = filmLuminanceLevelAdaptationFactor(LA);
    const float Nbb = 0.725 * pow(1.0 / n, 0.2);
    const float Ncb = Nbb;
    const float z = 1.48 + sqrt(n);

    const float3 dRGB = float3(
        D * Yw / rgbWhite.x + 1.0 - D,
        D * Yw / rgbWhite.y + 1.0 - D,
        D * Yw / rgbWhite.z + 1.0 - D
    );
    const float3 rgbWhiteCompressed = filmResponseCompressionForward(dRGB * rgbWhite, FL);
    const float aw = filmAchromaticResponse(rgbWhiteCompressed, Nbb);

    const float JPrime = max(J, 1e-6);
    const float t = filmSpow(
        C / (sqrt(JPrime / 100.0) * filmSpow(1.64 - pow(0.29, n), 0.73)),
        1.0 / 0.9
    );
    const float et = filmEccentricityFactor(h);
    const float A = aw * filmSpow(J / 100.0, 1.0 / (0.69 * z));

    const float P1 = (50000.0 / 13.0) * 1.0 * Ncb * et / t;
    const float P2 = A / Nbb + 0.305;
    const float P3 = 21.0 / 20.0;

    const float hr = h * (FILM_PI / 180.0);
    const float sinHR = sin(hr);
    const float cosHR = cos(hr);
    float a = 0.0;
    float b = 0.0;
    if (abs(sinHR) >= abs(cosHR)) {
        const float P4 = P1 / sinHR;
        const float nValue = P2 * (2.0 + P3) * (460.0 / 1403.0);
        b = nValue / (
            P4 + (2.0 + P3) * (220.0 / 1403.0) * (cosHR / sinHR)
                - (27.0 / 1403.0) + P3 * (6300.0 / 1403.0)
        );
        a = b * (cosHR / sinHR);
    } else {
        const float P5 = P1 / cosHR;
        const float nValue = P2 * (2.0 + P3) * (460.0 / 1403.0);
        a = nValue / (
            P5 + (2.0 + P3) * (220.0 / 1403.0)
                - ((27.0 / 1403.0) - P3 * (6300.0 / 1403.0)) * (sinHR / cosHR)
        );
        b = a * (sinHR / cosHR);
    }
    if (t == 0.0) {
        a = 0.0;
        b = 0.0;
    }

    const float3 rgbA = float3(
        (460.0 * P2 + 451.0 * a + 288.0 * b) / 1403.0,
        (460.0 * P2 - 891.0 * a - 261.0 * b) / 1403.0,
        (460.0 * P2 - 220.0 * a - 6300.0 * b) / 1403.0
    );

    const float3 rgbCompressed = filmResponseCompressionInverse(rgbA, FL);
    const float3 rgb = rgbCompressed / dRGB;
    return filmCAM16InverseConeResponse(rgb);
}

/// The CAM16-UCS coordinates of an XYZ triplet (the scale 1 domain).
inline float3 filmXYZToCAM16UCS(
    float3 xyz,
    float3 xyzWhite,
    float LA,
    float Yb
) {
    const float4 spec = filmCAM16Forward(xyz * 100.0, xyzWhite * 100.0, LA, Yb);
    const float J = spec.x;
    const float M = spec.z;
    const float h = spec.w;

    const float c1 = 0.007;
    const float c2 = 0.0228;
    const float Jp = ((1.0 + 100.0 * c1) * J) / (1.0 + c1 * J);
    const float Mp = (1.0 / c2) * log(1.0 + c2 * M);
    const float hr = h * (FILM_PI / 180.0);
    return float3(Jp, Mp * cos(hr), Mp * sin(hr));
}

/// The XYZ tristimulus values of a CAM16-UCS triplet (the scale 1 domain).
inline float3 filmCAM16UCStoXYZ(
    float3 jab,
    float3 xyzWhite,
    float LA,
    float Yb
) {
    const float c1 = 0.007;
    const float c2 = 0.0228;
    const float Jp = jab.x;
    const float Mp = sqrt(jab.y * jab.y + jab.z * jab.z);
    const float J = -Jp / (c1 * Jp - 1.0 - 100.0 * c1);
    const float M = (exp(Mp * c2) - 1.0) / c2;
    const float h = atan2(jab.z, jab.y) * (180.0 / FILM_PI);
    const float FL = filmLuminanceLevelAdaptationFactor(LA);
    const float C = M / filmSpow(FL, 0.25);
    const float hue = h < 0.0 ? h + 360.0 : h;
    return filmCAM16Inverse(J, C, hue, xyzWhite * 100.0, LA, Yb) / 100.0;
}

// MARK: - The counter based random number generator

/// The 32 bit avalanche hash of a word.
///
/// The hash is the finaliser of Chris Wellons (`lowbias32`); it is the
/// executable specification of `FilmCounterRandom.hash32` of the Swift
/// side.
inline uint filmHash32(uint value) {
    uint x = value;
    x ^= x >> 16;
    x *= 0x7feb352du;
    x ^= x >> 15;
    x *= 0x846ca68bu;
    x ^= x >> 16;
    return x;
}

/// The hash of a counter.
///
/// The counter is `(seed, pixel, layer, channel, stream)`: the variate of a
/// pixel is a pure function of its coordinates, so the field does not
/// depend on the order of the pixels.
inline uint filmCounter(
    uint seed,
    uint pixel,
    uint layer,
    uint channel,
    uint stream
) {
    uint hash = filmHash32(seed + 0x9E3779B9u);
    hash = filmHash32(hash ^ (pixel * 0x85EBCA6Bu));
    hash = filmHash32(hash ^ (layer * 0xC2B2AE35u));
    hash = filmHash32(hash ^ (channel * 0x27D4EB2Fu));
    hash = filmHash32(hash ^ (stream * 0x165667B1u));
    return hash;
}

/// A uniform variate in `[0, 1)` from a hash.
///
/// The 24 high bits of the hash are used: they are the ones a `float` can
/// represent exactly.
inline float filmUniform(uint hash) {
    return float(hash >> 8) * (1.0 / 16777216.0);
}

/// A standard normal variate from two hashes (the Box-Muller transform).
inline float filmNormal(uint first, uint second) {
    const float u1 = max(filmUniform(first), 1e-7);
    const float u2 = filmUniform(second);
    return sqrt(-2.0 * log(u1)) * cos(2.0 * M_PI_F * u2);
}

/// A Poisson variate (the fast kernel of the upstream).
inline int filmPoisson(
    float rate,
    uint seed,
    uint pixel,
    uint layer,
    uint channel
) {
    if (rate <= 0.0) {
        return 0;
    }
    if (rate < 30.0) {
        // Knuth's product method.
        const float limit = exp(-rate);
        float product = 1.0;
        int k = 0;
        do {
            product *= filmUniform(filmCounter(
                seed, pixel, layer, channel, 0x1000u + uint(k)
            ));
            k += 1;
        } while (product > limit && k < 1000);
        return k - 1;
    }
    // The normal approximation of the upstream.
    const float z = filmNormal(
        filmCounter(seed, pixel, layer, channel, 0x2000u),
        filmCounter(seed, pixel, layer, channel, 0x2001u)
    );
    const float sample = rint(rate + sqrt(rate) * z);
    return max(0, int(sample));
}

/// A binomial variate (the fast kernel of the upstream).
inline int filmBinomial(
    int n,
    float p,
    uint seed,
    uint pixel,
    uint layer,
    uint channel
) {
    if (n <= 0 || p <= 0.0) {
        return 0;
    }
    if (p >= 1.0) {
        return n;
    }
    if (n < 25) {
        // The direct simulation of the upstream.
        int count = 0;
        for (int trial = 0; trial < n; ++trial) {
            const float variate = filmUniform(filmCounter(
                seed, pixel, layer, channel, 0x3000u + uint(trial)
            ));
            if (variate < p) {
                count += 1;
            }
        }
        return count;
    }
    const float mean = float(n) * p;
    const float variance = float(n) * p * (1.0 - p);
    if (variance > 10.0) {
        // The normal approximation of the upstream.
        const float z = filmNormal(
            filmCounter(seed, pixel, layer, channel, 0x4000u),
            filmCounter(seed, pixel, layer, channel, 0x4001u)
        );
        const float sample = rint(mean + sqrt(variance) * z);
        return min(max(int(sample), 0), n);
    }
    // The inversion of the cumulative distribution.
    const float q = 1.0 - p;
    const float ratio = p / q;
    const float u = filmUniform(filmCounter(seed, pixel, layer, channel, 0x4002u));
    float cdf = 0.0;
    float probability = pow(q, float(n));
    int k = 0;
    while (cdf < u && k <= n) {
        cdf += probability;
        if (k < n) {
            probability *= float(n - k) / float(k + 1) * ratio;
        }
        k += 1;
    }
    return k - 1;
}

/// A lognormal variate with the given parameters of the underlying normal.
inline float filmLognormal(
    float mu,
    float sigma,
    uint seed,
    uint pixel,
    uint layer,
    uint channel
) {
    if (sigma < 1e-6) {
        return exp(mu);
    }
    const float z = filmNormal(
        filmCounter(seed, pixel, layer, channel, 0x5000u),
        filmCounter(seed, pixel, layer, channel, 0x5001u)
    );
    return exp(mu + sigma * z);
}

/// A lognormal variate with the given mean and standard deviation in linear
/// space.
inline float filmLognormalFromMeanStd(
    float mean,
    float std,
    uint seed,
    uint pixel,
    uint layer,
    uint channel
) {
    float mu = 0.0;
    float sigma = 0.0;
    if (mean > 0.0) {
        const float sigmaSquared = log(1.0 + (std * std) / (mean * mean));
        sigma = sqrt(sigmaSquared);
        mu = log(mean) - sigmaSquared / 2.0;
    }
    return filmLognormal(mu, sigma, seed, pixel, layer, channel);
}

// MARK: - The exact samplers of the grain

// The largest uniform variate the single precision can represent below one
// (`1 - 2^-24`).  The uniform of the counter based generator is built from
// the 24 high bits of a hash, so it is always below this bound; the clamp
// only protects the samplers against a uniform of one.
#define FILM_MAX_UNIFORM 0.99999994
// The bound of the walk of the inversion of the cumulative distribution.
//
// The terms of a distribution decay geometrically beyond the mode, so the
// walk stops on the underflow of the probability or on the stall of the
// accumulation long before the bound: the bound is a safety net (a
// parameter that is not a number would otherwise make the walk run for
// billions of iterations).
#define FILM_MAX_EXACT_STEPS 1048576

/// The natural logarithm of the gamma function.
///
/// The Lanczos approximation (the nine coefficients of `g = 7`), i.e. the
/// executable specification of `Float32ExactSamplers.logGamma` of the
/// Swift side (`Sources/FilmPhysics/Float32ExactSamplers.swift`).
///
/// - Parameter z: the argument.
/// - Returns: the natural logarithm of the gamma function.
inline float filmLogGamma(float z) {
    if (z < 0.5) {
        // The reflection formula.
        return log(M_PI_F / abs(sin(M_PI_F * z))) - filmLogGamma(1.0 - z);
    }
    const float shifted = z - 1.0;
    float sum = 0.99999999999980993;
    sum += 676.5203681218851 / (shifted + 1.0);
    sum += -1259.1392167224028 / (shifted + 2.0);
    sum += 771.32342877765313 / (shifted + 3.0);
    sum += -176.61502916214059 / (shifted + 4.0);
    sum += 12.507343278686905 / (shifted + 5.0);
    sum += -0.13857109526572012 / (shifted + 6.0);
    sum += 9.9843695780195716e-6 / (shifted + 7.0);
    sum += 1.5056327351493116e-7 / (shifted + 8.0);
    const float t = shifted + 7.5;
    return 0.5 * log(2.0 * M_PI_F) + (shifted + 0.5) * log(t) - t + log(sum);
}

/// The correction of the Stirling expansion of the logarithm of the gamma
/// function.
///
/// It is the difference between the exact logarithm of the gamma function
/// and its main term.  For a large argument the Bernoulli series is used;
/// for a small argument the exact difference is computed (both terms are
/// small, so the difference is accurate).
///
/// - Parameter z: the argument.
/// - Returns: the correction.
inline float filmStirlingCorrection(float z) {
    if (z <= 0.0) {
        return 0.0;
    }
    if (z < 8.0) {
        return filmLogGamma(z) - ((z - 0.5) * log(z) - z + 0.5 * log(2.0 * M_PI_F));
    }
    // The Bernoulli numbers `B(2j)` divided by `2j(2j-1)`, the powers of
    // `z` computed by repeated multiplication (the series is truncated by
    // the single precision anyway).
    const float z2 = z * z;
    float power = z;
    float sum = 0.0;
    sum += (1.0 / 12.0) / power;
    power *= z2;
    sum += (-1.0 / 360.0) / power;
    power *= z2;
    sum += (1.0 / 1260.0) / power;
    power *= z2;
    sum += (-1.0 / 1680.0) / power;
    power *= z2;
    sum += (1.0 / 1188.0) / power;
    power *= z2;
    sum += (-691.0 / 360360.0) / power;
    power *= z2;
    sum += (1.0 / 156.0) / power;
    power *= z2;
    sum += (-3617.0 / 122400.0) / power;
    power *= z2;
    sum += (43867.0 / 244188.0) / power;
    power *= z2;
    sum += (-174611.0 / 125400.0) / power;
    return sum;
}

/// The logarithm of the probability of a Poisson distribution.
///
/// The evaluation is **cancellation free**: the terms of the Stirling
/// expansion are combined into the relative entropy of the distribution, so
/// that the error of the result is of the order of the rounding of the
/// result itself (and not of the order of the rounding of the terms, which
/// are of the order of `k·log(λ)`).
///
/// - Parameters:
///   - lambda: the mean of the distribution.
///   - k: the value.
/// - Returns: the logarithm of the probability of `k`.
inline float filmLogPoissonProbability(float lambda, int k) {
    if (lambda <= 0.0 || k < 0) {
        return -INFINITY;
    }
    if (k == 0) {
        return -lambda;
    }
    const float count = float(k);
    const float excess = count + 1.0 - lambda;
    float value = -count * log1p(excess / lambda) + excess;
    value -= 0.5 * log(2.0 * M_PI_F * (count + 1.0));
    value -= filmStirlingCorrection(count + 1.0);
    return value;
}

/// The logarithm of the probability of a binomial distribution.
///
/// The evaluation is **cancellation free**, like the one of the Poisson.
///
/// - Parameters:
///   - n: the number of trials.
///   - k: the number of successes.
///   - p: the probability of a success.
/// - Returns: the logarithm of the probability of `k`.
inline float filmLogBinomialProbability(int n, int k, float p) {
    if (n <= 0 || k < 0 || k > n) {
        return -INFINITY;
    }
    if (p <= 0.0 || p >= 1.0) {
        return -INFINITY;
    }
    const float q = 1.0 - p;
    if (k == 0) {
        return float(n) * log(q);
    }
    if (k == n) {
        return float(n) * log(p);
    }
    const float trials = float(n);
    const float successes = float(k);
    const float failures = float(n - k);
    float value = successes * log1p(
        (p * (trials + 1.0) - (successes + 1.0)) / (successes + 1.0)
    );
    value += failures * log1p(
        (q * (trials + 1.0) - (failures + 1.0)) / (failures + 1.0)
    );
    value += 0.5 * log(
        (trials + 1.0) / (2.0 * M_PI_F * (successes + 1.0) * (failures + 1.0))
    );
    value += 1.0;
    value += filmStirlingCorrection(trials + 1.0);
    value -= filmStirlingCorrection(successes + 1.0);
    value -= filmStirlingCorrection(failures + 1.0);
    return value;
}

/// The series expansion of the lower incomplete gamma function.
///
/// - Parameters:
///   - a: the shape of the gamma distribution.
///   - x: the argument.
///   - front: the front factor of the expansion.
/// - Returns: the value of the series.
inline float filmGammaSeries(float a, float x, float front) {
    // The convergence threshold of the single precision (the CPU reference
    // uses `3e-16`, the threshold of the double precision).
    const float epsilon = 1e-7;
    float ap = a;
    float sum = 1.0 / a;
    float delta = sum;
    int iterations = 0;
    while (iterations < 1000) {
        ap += 1.0;
        delta *= x / ap;
        sum += delta;
        if (abs(delta) < abs(sum) * epsilon) {
            break;
        }
        iterations += 1;
    }
    return sum * front;
}

/// The continued fraction expansion of the upper incomplete gamma function.
///
/// - Parameters:
///   - a: the shape of the gamma distribution.
///   - x: the argument.
///   - front: the front factor of the expansion.
/// - Returns: the value of the continued fraction.
inline float filmGammaContinuedFraction(float a, float x, float front) {
    const float epsilon = 1e-7;
    // The floor of the denominators: the single precision cannot represent
    // `1e-300` (it would be a zero, and the division by it an infinity).
    const float tiny = 1e-30;
    float b = x + 1.0 - a;
    float c = 1.0 / tiny;
    float d = 1.0 / b;
    float h = d;
    int iterations = 0;
    while (iterations < 1000) {
        const float i = float(iterations + 1);
        const float an = -i * (i - a);
        b += 2.0;
        d = an * d + b;
        if (abs(d) < tiny) { d = tiny; }
        c = b + an / c;
        if (abs(c) < tiny) { c = tiny; }
        d = 1.0 / d;
        const float delta = d * c;
        h *= delta;
        if (abs(delta - 1.0) < epsilon) { break; }
        iterations += 1;
    }
    return front * h;
}

/// The regularised upper incomplete gamma function `Q(a, x)`, with the
/// **cancellation free** evaluation of its front factor.
///
/// `Q(a, x) = Γ(a, x) / Γ(a)` is the tail of the gamma distribution; the
/// cumulative distribution of a Poisson distribution is
/// `P(X ≤ k) = Q(k + 1, λ)`.
///
/// - Parameters:
///   - a: the shape of the gamma distribution (an integer ≥ 1).
///   - x: the argument.
/// - Returns: the value of `Q(a, x)`.
inline float filmRegularizedGammaQ(int a, float x) {
    if (a <= 0) { return 1.0; }
    if (x <= 0.0) { return 1.0; }
    if (!isfinite(x)) { return 0.0; }
    const float shape = float(a);
    const float front = exp(filmLogPoissonProbability(x, a - 1) + log(x));
    if (x < shape + 1.0) {
        return 1.0 - filmGammaSeries(shape, x, front);
    }
    return filmGammaContinuedFraction(shape, x, front);
}

/// The continued fraction of the incomplete beta function (the modified
/// Lentz method).
///
/// - Parameters:
///   - a: the first shape.
///   - b: the second shape.
///   - x: the argument, in `[0, 1]`.
/// - Returns: the value of the continued fraction.
inline float filmBetaContinuedFraction(float a, float b, float x) {
    const float epsilon = 1e-7;
    const float tiny = 1e-30;
    const float qab = a + b;
    const float qap = a + 1.0;
    const float qam = a - 1.0;
    float c = 1.0;
    float d = 1.0 - qab * x / qap;
    if (abs(d) < tiny) { d = tiny; }
    d = 1.0 / d;
    float h = d;
    int m = 1;
    while (m <= 300) {
        const float m2 = 2.0 * float(m);
        // The even step.
        float numerator = float(m) * (b - float(m)) * x / ((qam + m2) * (a + m2));
        d = 1.0 + numerator * d;
        if (abs(d) < tiny) { d = tiny; }
        c = 1.0 + numerator / c;
        if (abs(c) < tiny) { c = tiny; }
        d = 1.0 / d;
        h *= d * c;
        // The odd step.
        numerator = -(a + float(m)) * (qab + float(m)) * x
            / ((a + m2) * (qap + m2));
        d = 1.0 + numerator * d;
        if (abs(d) < tiny) { d = tiny; }
        c = 1.0 + numerator / c;
        if (abs(c) < tiny) { c = tiny; }
        d = 1.0 / d;
        const float delta = d * c;
        h *= delta;
        if (abs(delta - 1.0) < epsilon) { break; }
        m += 1;
    }
    return h;
}

/// The regularised incomplete beta function `I_x(a, b)`, with the
/// **cancellation free** evaluation of its front factor.
///
/// `I_x(a, b)` is the cumulative distribution function of the beta
/// distribution; the cumulative distribution of a binomial distribution is
/// `P(X ≤ k) = I_p(k + 1, n - k)`.
///
/// - Parameters:
///   - a: the first shape (an integer ≥ 1).
///   - b: the second shape (an integer ≥ 1).
///   - x: the argument, in `[0, 1]`.
/// - Returns: the value of `I_x(a, b)`.
inline float filmRegularizedIncompleteBeta(int a, int b, float x) {
    if (a <= 0 || b <= 0) { return NAN; }
    if (x <= 0.0) { return 0.0; }
    if (x >= 1.0) { return 1.0; }
    const int n = a + b - 1;
    // The front factor is `x·b·P(a - 1; n, x)`: the probability of the
    // binomial distribution of `n` trials at `a - 1` successes, times the
    // factor of the tail of the beta distribution.
    const float front = exp(
        filmLogBinomialProbability(n, a - 1, x) + log(x) + log(float(b))
    );
    if (x < (float(a) + 1.0) / (float(a + b) + 2.0)) {
        return front * filmBetaContinuedFraction(float(a), float(b), x) / float(a);
    }
    return 1.0 - front * filmBetaContinuedFraction(float(b), float(a), 1.0 - x) / float(b);
}

/// An exact Poisson variate.
///
/// The variate is drawn from the **exact** Poisson distribution, i.e. the
/// distribution of the default path of the upstream (the SciPy `poisson`
/// generator) and not from the normal approximation of the fast kernel of
/// the upstream: the inversion of the cumulative distribution, around the
/// mode of the distribution (the mode of a Poisson distribution is
/// `floor(λ)`).
///
/// The uniform variate is the 24 high bits of the hash of the stream
/// `0x6000` (the high bits of the 53 bit uniform of the CPU reference,
/// `FilmCounterRandom.Stream.poissonExactA`): the two implementations draw
/// their variates from the **same** uniforms.
///
/// The algorithm is the executable specification of
/// `Float32ExactSamplers.poisson(lambda:uniform:)` of the Swift side.
///
/// - Parameters:
///   - rate: the mean of the distribution.
///   - seed: the seed of the stream.
///   - pixel: the index of the pixel.
///   - layer: the index of the emulsion layer.
///   - channel: the index of the colour channel.
/// - Returns: the variate.
inline int filmPoissonExact(
    float rate,
    uint seed,
    uint pixel,
    uint layer,
    uint channel
) {
    if (rate <= 0.0 || !isfinite(rate)) {
        return 0;
    }
    const float u = min(max(
        filmUniform(filmCounter(seed, pixel, layer, channel, 0x6000u)), 0.0
    ), FILM_MAX_UNIFORM);

    // The mode of the distribution and its probability.
    const int mode = int(floor(rate));
    const float modeProbability = exp(filmLogPoissonProbability(rate, mode));
    if (!(modeProbability > 0.0) || !isfinite(modeProbability)) {
        return mode;
    }

    // The cumulative distribution below the mode: `P(X ≤ mode - 1)`.
    const float below = mode > 0 ? filmRegularizedGammaQ(mode, rate) : 0.0;
    const float top = below + modeProbability;

    if (u < below) {
        // The variate is below the mode: the cumulative distribution is
        // walked **down** from the mode.  The mass that is subtracted from
        // the cumulative distribution is accumulated with a compensated
        // summation, so that the rounding of the accumulation stays of the
        // order of the rounding of the result.
        int k = mode;
        float probability = modeProbability;     // P(k)
        float mass = 0.0;                        // the mass of (k, mode]
        float compensation = 0.0;
        while (k > 0) {
            // The cumulative distribution of `k - 1`.
            const float previous = top - mass - probability;
            if (previous <= u) { break; }
            const float adjusted = probability - compensation;
            const float updated = mass + adjusted;
            compensation = (updated - mass) - adjusted;
            mass = updated;
            probability *= float(k) / rate;      // P(k - 1)
            k -= 1;
        }
        return k;
    }

    if (u < top) {
        // The variate is the mode itself.
        return mode;
    }

    // The variate is above the mode: the cumulative distribution is walked
    // **up** from the mode.
    int k = mode;
    float probability = modeProbability;         // P(k)
    float mass = 0.0;                            // the mass of (mode, k]
    float compensation = 0.0;
    while (k < FILM_MAX_EXACT_STEPS) {
        const float next = probability * rate / float(k + 1);   // P(k + 1)
        if (next == 0.0) {
            // The probability underflowed: the mass of the tail beyond
            // this point is below the resolution of the single precision,
            // so the uniform cannot fall in it.
            break;
        }
        const float updated = mass + next;
        if (updated == mass && top + mass > u) {
            // The accumulation of the cumulative distribution stalled: the
            // remaining mass is below the rounding of the sum.  The
            // variate is the last `k` whose probability is not negligible
            // (and **not** a far outlier).
            break;
        }
        const float adjusted = next - compensation;
        const float summed = mass + adjusted;
        compensation = (summed - mass) - adjusted;
        mass = summed;
        probability = next;
        k += 1;
        if (top + mass > u) { break; }
    }
    return k;
}

/// An exact binomial variate.
///
/// The variate is drawn from the **exact** binomial distribution, i.e. the
/// distribution of the default path of the upstream (the SciPy `binom`
/// generator) and not from the normal approximation of the fast kernel of
/// the upstream: the inversion of the cumulative distribution, around the
/// mode of the distribution (the mode of a binomial distribution is
/// `floor((n + 1) p)`).
///
/// The uniform variate is the 24 high bits of the hash of the stream
/// `0x7000` (the high bits of the 53 bit uniform of the CPU reference,
/// `FilmCounterRandom.Stream.binomialExactA`).
///
/// The algorithm is the executable specification of
/// `Float32ExactSamplers.binomial(n:p:uniform:)` of the Swift side.
///
/// - Parameters:
///   - n: the number of trials.
///   - p: the probability of a success.
///   - seed: the seed of the stream.
///   - pixel: the index of the pixel.
///   - layer: the index of the emulsion layer.
///   - channel: the index of the colour channel.
/// - Returns: the number of successes.
inline int filmBinomialExact(
    int n,
    float p,
    uint seed,
    uint pixel,
    uint layer,
    uint channel
) {
    if (n <= 0 || p <= 0.0) {
        return 0;
    }
    if (p >= 1.0) {
        return n;
    }
    const float u = min(max(
        filmUniform(filmCounter(seed, pixel, layer, channel, 0x7000u)), 0.0
    ), FILM_MAX_UNIFORM);
    const float q = 1.0 - p;

    // The mode of the distribution and its probability.
    const int mode = min(max(int(floor((float(n) + 1.0) * p)), 0), n);
    const float modeProbability = exp(filmLogBinomialProbability(n, mode, p));
    if (!(modeProbability > 0.0) || !isfinite(modeProbability)) {
        return mode;
    }

    // The cumulative distribution below the mode: `P(X ≤ mode - 1)`.  The
    // identity of the binomial distribution is
    // `P(X ≤ k) = I_(1-p)(n - k, k + 1)`.
    const float below = mode > 0
        ? filmRegularizedIncompleteBeta(n - mode + 1, mode, q)
        : 0.0;
    const float top = below + modeProbability;

    if (u < below) {
        // The variate is below the mode: the cumulative distribution is
        // walked **down** from the mode.
        int k = mode;
        float probability = modeProbability;     // P(k)
        float mass = 0.0;                        // the mass of (k, mode]
        float compensation = 0.0;
        while (k > 0) {
            const float previous = top - mass - probability;
            if (previous <= u) { break; }
            const float adjusted = probability - compensation;
            const float updated = mass + adjusted;
            compensation = (updated - mass) - adjusted;
            mass = updated;
            probability *= float(k) * q / (float(n - k + 1) * p);   // P(k - 1)
            k -= 1;
        }
        return k;
    }

    if (u < top) {
        // The variate is the mode itself.
        return mode;
    }

    // The variate is above the mode: the cumulative distribution is walked
    // **up** from the mode, until the end of the support (the binomial
    // distribution is bounded, so the walk always terminates).
    int k = mode;
    float probability = modeProbability;         // P(k)
    float mass = 0.0;                            // the mass of (mode, k]
    float compensation = 0.0;
    while (k < n) {
        const float next = probability * float(n - k) * p
            / (float(k + 1) * q);                // P(k + 1)
        if (next == 0.0) {
            // The probability underflowed: the mass of the tail beyond
            // this point is negligible.
            break;
        }
        const float updated = mass + next;
        if (updated == mass && top + mass > u) {
            // The accumulation stalled: the variate is the last `k` whose
            // probability is not negligible.
            break;
        }
        const float adjusted = next - compensation;
        const float summed = mass + adjusted;
        compensation = (summed - mass) - adjusted;
        mass = summed;
        probability = next;
        k += 1;
        if (top + mass > u) { break; }
    }
    // The support ends at `n`: when the accumulated cumulative distribution
    // never exceeds the uniform (the sum of the terms of the distribution
    // is one, up to the rounding of the arithmetic), the variate is the
    // last `k` of the support.
    return k;
}

// MARK: - The kernels of the per pixel chain

/// The spectral upsampling: the camera image to the raw response.
kernel void filmSpectralUpsample(
    device const float *rgbIn [[buffer(0)]],
    device float *rawOut [[buffer(1)]],
    device const float *matrix [[buffer(2)]],
    device const float *tcLUT [[buffer(3)]],
    constant FilmPlanParams &params [[buffer(4)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= params.width || gid.y >= params.height) {
        return;
    }
    const uint pixel = gid.y * params.width + gid.x;
    const int cctf = int(params.inputCCTF);

    const float r = filmDecodeInput(rgbIn[pixel * 3], cctf);
    const float g = filmDecodeInput(rgbIn[pixel * 3 + 1], cctf);
    const float b = filmDecodeInput(rgbIn[pixel * 3 + 2], cctf);

    const float3 xyz = float3(
        matrix[0] * r + matrix[1] * g + matrix[2] * b,
        matrix[3] * r + matrix[4] * g + matrix[5] * b,
        matrix[6] * r + matrix[7] * g + matrix[8] * b
    );

    float luminance = xyz.x + xyz.y + xyz.z;
    if (isnan(luminance)) {
        luminance = 0.0;
    }
    const float denominator = max(luminance, 1e-10);
    const float x = xyz.x / denominator;
    const float y = xyz.y / denominator;
    const float u = clamp((1.0 - x) * (1.0 - x), 0.0, 1.0);
    const float v = clamp(y / max(1.0 - x, 1e-10), 0.0, 1.0);

    const float3 response = filmTCLookup(tcLUT, params.tcLUTSize, u, v);
    rawOut[pixel * 3] = response.x * luminance * params.exposureScale;
    rawOut[pixel * 3 + 1] = response.y * luminance * params.exposureScale;
    rawOut[pixel * 3 + 2] = response.z * luminance * params.exposureScale;
}

/// The first stage of the maximum reduction.
///
/// The kernel **must** be dispatched with exactly `FILM_REDUCE_THREADS`
/// threads (the Swift side dispatches 1024 threads, in groups of 256).
/// The grid is split in `FILM_REDUCE_THREADS / threads_per_threadgroup`
/// contiguous blocks — one per thread group — and the threads of a group
/// stride over the block: every value of the field is therefore read
/// **exactly once**, and the maximum of the field is the maximum of the
/// `FILM_REDUCE_THREADS` partial results.
kernel void filmReduceMaxPartial(
    device const float *values [[buffer(0)]],
    device float *partials [[buffer(1)]],
    constant FilmPlanParams &params [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 groupSize [[threads_per_threadgroup]]
) {
    const uint total = params.width * params.height * 3;
    // The grid is one dimensional: the position of the thread is its `x`.
    const uint position = gid.x;
    // The number of the threads of the group: it is the stride of the
    // loop, and it must never be zero (the loop would never end).
    const uint threads = max(groupSize.x, 1u);
    if (position >= FILM_REDUCE_THREADS) {
        return;
    }
    const uint groupCount = max(FILM_REDUCE_THREADS / threads, 1u);
    const uint groupIndex = position / threads;
    const uint threadInGroup = position % threads;
    const uint block = (total + groupCount - 1) / groupCount;
    const uint start = groupIndex * block;
    const uint end = min(start + block, total);

    float maximum = -INFINITY;
    for (uint index = start + threadInGroup; index < end; index += threads) {
        maximum = max(maximum, values[index]);
    }
    partials[position] = maximum;
}

/// The second stage of the maximum reduction.
kernel void filmReduceMaxFinal(
    device const float *partials [[buffer(0)]],
    device float *result [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x != 0) {
        return;
    }
    float maximum = -INFINITY;
    for (uint index = 0; index < FILM_REDUCE_THREADS; ++index) {
        maximum = max(maximum, partials[index]);
    }
    result[0] = maximum;
}

/// The highlight boost of the negative.
kernel void filmBoostHighlights(
    device const float *rawIn [[buffer(0)]],
    device float *rawOut [[buffer(1)]],
    device const float *maximum [[buffer(2)]],
    constant FilmPlanParams &params [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= params.width || gid.y >= params.height) {
        return;
    }
    const uint pixel = gid.y * params.width + gid.x;
    const float maxRaw = maximum[0];
    if (maxRaw <= 0.0 || !isfinite(maxRaw)) {
        // Without a maximum the boost is the identity.
        for (uint channel = 0; channel < 3; ++channel) {
            rawOut[pixel * 3 + channel] = rawIn[pixel * 3 + channel];
        }
        return;
    }
    const float rawX0 = min(max(0.184 * pow(2.0, params.protectEV), 0.0), maxRaw);
    if (rawX0 == maxRaw) {
        for (uint channel = 0; channel < 3; ++channel) {
            rawOut[pixel * 3 + channel] = rawIn[pixel * 3 + channel];
        }
        return;
    }
    const float a = pow(28.0, 1.0 - params.boostRange);
    const float x0 = rawX0 / maxRaw;
    const float denominator = exp(a * (1.0 - x0)) - a * (1.0 - x0) - 1.0;
    const float k = (pow(2.0, params.boostEV) - 1.0) / denominator;
    const float inverseMaxRaw = 1.0 / maxRaw;
    const float boostScale = k * maxRaw;

    for (uint channel = 0; channel < 3; ++channel) {
        const float value = rawIn[pixel * 3 + channel];
        if (value <= rawX0) {
            rawOut[pixel * 3 + channel] = value;
        } else {
            const float dx = (value - rawX0) * inverseMaxRaw;
            rawOut[pixel * 3 + channel] = value
                + boostScale * (exp(a * dx) - a * dx - 1.0);
        }
    }
}

/// The linear to log10 conversion of an exposure.
kernel void filmLinearToLog(
    device const float *src [[buffer(0)]],
    device float *dst [[buffer(1)]],
    constant FilmExposureParams &params [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= params.width || gid.y >= params.height) {
        return;
    }
    const uint pixel = gid.y * params.width + gid.x;
    for (uint channel = 0; channel < 3; ++channel) {
        const float value = src[pixel * 3 + channel] * params.scale + params.offset;
        dst[pixel * 3 + channel] = log10(max(value, 0.0) + 1e-10);
    }
}

/// The evaluation of the characteristic curves of the film.
kernel void filmFilmDensity(
    device const float *exposureIn [[buffer(0)]],
    device float *dst [[buffer(1)]],
    device const float *curve [[buffer(2)]],
    constant FilmPlanParams &params [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= params.width || gid.y >= params.height) {
        return;
    }
    const uint pixel = gid.y * params.width + gid.x;
    for (uint channel = 0; channel < 3; ++channel) {
        dst[pixel * 3 + channel] = filmSampleCurve(
            curve,
            params.filmCurveCount,
            params.filmCurveStart,
            params.filmCurveStep,
            exposureIn[pixel * 3 + channel],
            channel
        );
    }
}

/// The evaluation of the characteristic curves of the film, with the
/// correction of the DIR couplers.
kernel void filmFilmDensityCoupled(
    device const float *exposureIn [[buffer(0)]],
    device const float *correctionIn [[buffer(1)]],
    device float *dst [[buffer(2)]],
    device const float *curve [[buffer(3)]],
    constant FilmPlanParams &params [[buffer(4)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= params.width || gid.y >= params.height) {
        return;
    }
    const uint pixel = gid.y * params.width + gid.x;
    for (uint channel = 0; channel < 3; ++channel) {
        const float exposure = exposureIn[pixel * 3 + channel]
            - correctionIn[pixel * 3 + channel];
        dst[pixel * 3 + channel] = filmSampleCurve(
            curve,
            params.filmCurveCount,
            params.filmCurveBeforeStart,
            params.filmCurveBeforeStep,
            exposure,
            channel
        );
    }
}

/// The correction the released inhibitors of the DIR couplers cause.
kernel void filmCouplerCorrection(
    device const float *cmyIn [[buffer(0)]],
    device float *dst [[buffer(1)]],
    device const float *coupler [[buffer(2)]],
    constant FilmPlanParams &params [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= params.width || gid.y >= params.height) {
        return;
    }
    const uint pixel = gid.y * params.width + gid.x;
    float sr = 0.0;
    float sg = 0.0;
    float sb = 0.0;
    if (params.couplerPositive > 0.5) {
        sr = coupler[9] - cmyIn[pixel * 3];
        sg = coupler[10] - cmyIn[pixel * 3 + 1];
        sb = coupler[11] - cmyIn[pixel * 3 + 2];
    } else {
        sr = cmyIn[pixel * 3];
        sg = cmyIn[pixel * 3 + 1];
        sb = cmyIn[pixel * 3 + 2];
    }
    for (uint receiver = 0; receiver < 3; ++receiver) {
        const float amount = sr * coupler[receiver]
            + sg * coupler[3 + receiver]
            + sb * coupler[6 + receiver];
        dst[pixel * 3 + receiver] = amount;
    }
}

/// The exposure of the paper.
kernel void filmPrintingExposure(
    device const float *cmyIn [[buffer(0)]],
    device float *dst [[buffer(1)]],
    device const float *filmChannelDensity [[buffer(2)]],
    device const float *filmBaseDensity [[buffer(3)]],
    device const float *printSensitivity [[buffer(4)]],
    device const float *printIlluminant [[buffer(5)]],
    device const float *preflash [[buffer(6)]],
    constant FilmPlanParams &params [[buffer(7)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= params.width || gid.y >= params.height) {
        return;
    }
    const uint pixel = gid.y * params.width + gid.x;
    const uint wavelengths = params.wavelengthCount;
    const float cr = cmyIn[pixel * 3];
    const float cg = cmyIn[pixel * 3 + 1];
    const float cb = cmyIn[pixel * 3 + 2];

    float totalR = 0.0;
    float totalG = 0.0;
    float totalB = 0.0;
    for (uint wavelength = 0; wavelength < wavelengths; ++wavelength) {
        float density = filmBaseDensity[wavelength];
        density += cr * filmChannelDensity[wavelength * 3];
        density += cg * filmChannelDensity[wavelength * 3 + 1];
        density += cb * filmChannelDensity[wavelength * 3 + 2];
        float value = pow(10.0, -density) * printIlluminant[wavelength];
        if (isnan(value)) {
            value = 0.0;
        }
        totalR += value * printSensitivity[wavelength * 3];
        totalG += value * printSensitivity[wavelength * 3 + 1];
        totalB += value * printSensitivity[wavelength * 3 + 2];
    }
    dst[pixel * 3] = max(totalR * params.exposureFactor + preflash[0], 0.0) + 1e-10;
    dst[pixel * 3 + 1] = max(totalG * params.exposureFactor + preflash[1], 0.0) + 1e-10;
    dst[pixel * 3 + 2] = max(totalB * params.exposureFactor + preflash[2], 0.0) + 1e-10;
}

/// The evaluation of the characteristic curves of the paper.
kernel void filmPrintDensity(
    device const float *exposureIn [[buffer(0)]],
    device float *dst [[buffer(1)]],
    device const float *curve [[buffer(2)]],
    constant FilmPlanParams &params [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= params.width || gid.y >= params.height) {
        return;
    }
    const uint pixel = gid.y * params.width + gid.x;
    for (uint channel = 0; channel < 3; ++channel) {
        dst[pixel * 3 + channel] = filmSampleCurve(
            curve,
            params.printCurveCount,
            params.printCurveStart,
            params.printCurveStep,
            exposureIn[pixel * 3 + channel],
            channel
        );
    }
}

/// The tristimulus values of the scanned print.
kernel void filmScanXYZ(
    device const float *cmyIn [[buffer(0)]],
    device float *dst [[buffer(1)]],
    device const float *printChannelDensity [[buffer(2)]],
    device const float *printBaseDensity [[buffer(3)]],
    device const float *scanIlluminant [[buffer(4)]],
    device const float *cmfs [[buffer(5)]],
    constant FilmPlanParams &params [[buffer(6)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= params.width || gid.y >= params.height) {
        return;
    }
    const uint pixel = gid.y * params.width + gid.x;
    const uint wavelengths = params.wavelengthCount;
    const float cr = cmyIn[pixel * 3];
    const float cg = cmyIn[pixel * 3 + 1];
    const float cb = cmyIn[pixel * 3 + 2];

    float x = 0.0;
    float y = 0.0;
    float z = 0.0;
    for (uint wavelength = 0; wavelength < wavelengths; ++wavelength) {
        float density = printBaseDensity[wavelength];
        density += cr * printChannelDensity[wavelength * 3];
        density += cg * printChannelDensity[wavelength * 3 + 1];
        density += cb * printChannelDensity[wavelength * 3 + 2];
        float value = pow(10.0, -density) * scanIlluminant[wavelength];
        if (isnan(value)) {
            value = 0.0;
        }
        x += value * cmfs[wavelength * 3];
        y += value * cmfs[wavelength * 3 + 1];
        z += value * cmfs[wavelength * 3 + 2];
    }
    const float normalisation = params.scanNormalization;
    float3 xyz = float3(x / normalisation, y / normalisation, z / normalisation);
    xyz = max(xyz, 0.0) + 1e-10;

    if (params.correctionActive > 0.5) {
        const float corrected = clamp(
            params.correctionSlope * xyz.y + params.correctionOffset,
            0.0,
            1.0
        );
        const float scale = corrected / (xyz.y + 1e-10);
        xyz = xyz * scale;
    }
    dst[pixel * 3] = xyz.x;
    dst[pixel * 3 + 1] = xyz.y;
    dst[pixel * 3 + 2] = xyz.z;
}

/// The conversion of the tristimulus values into the linear RGB values.
kernel void filmXYZToRGB(
    device const float *xyzIn [[buffer(0)]],
    device float *dst [[buffer(1)]],
    device const float *matrix [[buffer(2)]],
    constant FilmPlanParams &params [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= params.width || gid.y >= params.height) {
        return;
    }
    const uint pixel = gid.y * params.width + gid.x;
    const float x = xyzIn[pixel * 3];
    const float y = xyzIn[pixel * 3 + 1];
    const float z = xyzIn[pixel * 3 + 2];
    dst[pixel * 3] = x * matrix[0] + y * matrix[3] + z * matrix[6];
    dst[pixel * 3 + 1] = x * matrix[1] + y * matrix[4] + z * matrix[7];
    dst[pixel * 3 + 2] = x * matrix[2] + y * matrix[5] + z * matrix[8];
}

/// The Reinhard knee of the gamut compression.
inline float filmReinhardKnee(float d, float threshold, float limit, float power) {
    if (d <= threshold) {
        return d;
    }
    const float scale = limit - threshold;
    const float x = (d - threshold) / scale;
    const float y = x / pow(1.0 + pow(x, power), 1.0 / power);
    return threshold + scale * y;
}

/// The maximum in-gamut chroma at a given lightness and hue.
inline float filmCMaxLookup(
    device const float *cMax,
    uint lightnessCount,
    uint hueCount,
    float lightnessStart,
    float lightnessStep,
    float hueStart,
    float hueStep,
    float lightness,
    float hue
) {
    if (hueCount == 0 || lightnessCount < 2) {
        return 0.0;
    }
    const float lightnessEnd = lightnessStart + lightnessStep * float(lightnessCount - 1);
    const float clampedLightness = clamp(lightness, lightnessStart, lightnessEnd);

    const float hueIndex = (hue - hueStart) / hueStep;
    const float hueFloor = floor(hueIndex);
    int hueLow = int(hueFloor) % int(hueCount);
    if (hueLow < 0) {
        hueLow += int(hueCount);
    }
    const int hueHigh = (hueLow + 1) % int(hueCount);
    const float hueFraction = hueIndex - hueFloor;

    const float lightnessIndex = (clampedLightness - lightnessStart)
        / (lightnessEnd - lightnessStart) * float(lightnessCount - 1);
    const float lightnessFloor = floor(lightnessIndex);
    const int lightnessLow = clamp(int(lightnessFloor), 0, int(lightnessCount) - 2);
    const int lightnessHigh = lightnessLow + 1;
    const float lightnessFraction = lightnessIndex - float(lightnessLow);

    const uint h0 = uint(hueLow);
    const uint h1 = uint(hueHigh);
    const uint l0 = uint(lightnessLow);
    const uint l1 = uint(lightnessHigh);
    const float v00 = cMax[l0 * hueCount + h0];
    const float v01 = cMax[l0 * hueCount + h1];
    const float v10 = cMax[l1 * hueCount + h0];
    const float v11 = cMax[l1 * hueCount + h1];
    return v00 * (1.0 - lightnessFraction) * (1.0 - hueFraction)
        + v01 * (1.0 - lightnessFraction) * hueFraction
        + v10 * lightnessFraction * (1.0 - hueFraction)
        + v11 * lightnessFraction * hueFraction;
}

/// The output gamut compression (the CAM16-UCS chroma reduction).
kernel void filmGamutCompress(
    device const float *rgbIn [[buffer(0)]],
    device float *dst [[buffer(1)]],
    device const float *rgbToXYZ [[buffer(2)]],
    device const float *xyzToRGB [[buffer(3)]],
    device const float *cMax [[buffer(4)]],
    constant FilmPlanParams &params [[buffer(5)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= params.width || gid.y >= params.height) {
        return;
    }
    if (params.gamutActive < 0.5) {
        const uint pixel = gid.y * params.width + gid.x;
        dst[pixel * 3] = rgbIn[pixel * 3];
        dst[pixel * 3 + 1] = rgbIn[pixel * 3 + 1];
        dst[pixel * 3 + 2] = rgbIn[pixel * 3 + 2];
        return;
    }
    const uint pixel = gid.y * params.width + gid.x;
    const float r = rgbIn[pixel * 3];
    const float g = rgbIn[pixel * 3 + 1];
    const float b = rgbIn[pixel * 3 + 2];

    const float3 xyz = float3(
        rgbToXYZ[0] * r + rgbToXYZ[1] * g + rgbToXYZ[2] * b,
        rgbToXYZ[3] * r + rgbToXYZ[4] * g + rgbToXYZ[5] * b,
        rgbToXYZ[6] * r + rgbToXYZ[7] * g + rgbToXYZ[8] * b
    );

    const float3 whiteXYZ = float3(params.whiteX, params.whiteY, params.whiteZ);
    float3 jab = filmXYZToCAM16UCS(xyz, whiteXYZ, params.cam16LA, params.cam16Yb);

    if (params.lightnessActive > 0.5) {
        const float normalised = jab.x / params.cam16WhiteJp;
        jab.x = filmReinhardKnee(
            normalised,
            params.lightnessKneeThreshold,
            params.lightnessKneeLimit,
            params.lightnessKneePower
        ) * params.cam16WhiteJp;
    }

    const float chroma = sqrt(jab.y * jab.y + jab.z * jab.z);
    const float hue = atan2(jab.z, jab.y);
    const float maximum = filmCMaxLookup(
        cMax,
        params.cMaxLightnessCount,
        params.cMaxHueCount,
        params.cMaxLightnessStart,
        params.cMaxLightnessStep,
        params.cMaxHueStart,
        params.cMaxHueStep,
        jab.x,
        hue
    );
    const float safeMaximum = max(maximum, 1e-9);
    const float normalised = chroma / safeMaximum;
    const float compressed = filmReinhardKnee(
        normalised,
        params.gamutKneeThreshold,
        params.gamutKneeLimit,
        params.gamutKneePower
    );
    const float newChroma = compressed * safeMaximum;
    const float3 newJab = float3(
        jab.x,
        newChroma * cos(hue),
        newChroma * sin(hue)
    );
    const float3 newXYZ = filmCAM16UCStoXYZ(
        newJab,
        whiteXYZ,
        params.cam16LA,
        params.cam16Yb
    );
    dst[pixel * 3] = xyzToRGB[0] * newXYZ.x + xyzToRGB[1] * newXYZ.y + xyzToRGB[2] * newXYZ.z;
    dst[pixel * 3 + 1] = xyzToRGB[3] * newXYZ.x + xyzToRGB[4] * newXYZ.y
        + xyzToRGB[5] * newXYZ.z;
    dst[pixel * 3 + 2] = xyzToRGB[6] * newXYZ.x + xyzToRGB[7] * newXYZ.y
        + xyzToRGB[8] * newXYZ.z;
}

/// The output transfer function.
kernel void filmEncodeOutput(
    device const float *src [[buffer(0)]],
    device float *dst [[buffer(1)]],
    device const float *matrix [[buffer(2)]],
    constant FilmPlanParams &params [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= params.width || gid.y >= params.height) {
        return;
    }
    const uint pixel = gid.y * params.width + gid.x;
    const float r = src[pixel * 3];
    const float g = src[pixel * 3 + 1];
    const float b = src[pixel * 3 + 2];
    const float3 value = float3(
        matrix[0] * r + matrix[1] * g + matrix[2] * b,
        matrix[3] * r + matrix[4] * g + matrix[5] * b,
        matrix[6] * r + matrix[7] * g + matrix[8] * b
    );
    if (params.outputEncoded > 0.5) {
        dst[pixel * 3] = filmSRGBEncode(value.x);
        dst[pixel * 3 + 1] = filmSRGBEncode(value.y);
        dst[pixel * 3 + 2] = filmSRGBEncode(value.z);
    } else {
        dst[pixel * 3] = value.x;
        dst[pixel * 3 + 1] = value.y;
        dst[pixel * 3 + 2] = value.z;
    }
}

// MARK: - The kernels of the spatial effects

/// The horizontal pass of the separable Gaussian filter.
kernel void filmBlurHorizontal(
    device const float *src [[buffer(0)]],
    device float *dst [[buffer(1)]],
    device const float *weights [[buffer(2)]],
    constant FilmBlurParams &params [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= params.width || gid.y >= params.height) {
        return;
    }
    const int radius = min(int(params.radius), FILM_MAX_BLUR_RADIUS);
    const int length = 2 * radius + 1;
    const uint pixel = gid.y * params.width + gid.x;
    const int column = int(gid.x);

    float s0 = 0.0;
    float s1 = 0.0;
    float s2 = 0.0;
    for (int offset = -radius; offset <= radius; ++offset) {
        const int source = filmReflectEdge(column + offset, int(params.width));
        const uint index = (gid.y * params.width + uint(source)) * 3;
        const float w0 = weights[uint(0 * length + (offset + radius))];
        const float w1 = weights[uint(1 * length + (offset + radius))];
        const float w2 = weights[uint(2 * length + (offset + radius))];
        s0 += src[index] * w0;
        s1 += src[index + 1] * w1;
        s2 += src[index + 2] * w2;
    }
    dst[pixel * 3] = s0;
    dst[pixel * 3 + 1] = s1;
    dst[pixel * 3 + 2] = s2;
}

/// The vertical pass of the separable Gaussian filter.
kernel void filmBlurVertical(
    device const float *src [[buffer(0)]],
    device float *dst [[buffer(1)]],
    device const float *weights [[buffer(2)]],
    constant FilmBlurParams &params [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= params.width || gid.y >= params.height) {
        return;
    }
    const int radius = min(int(params.radius), FILM_MAX_BLUR_RADIUS);
    const int length = 2 * radius + 1;
    const uint pixel = gid.y * params.width + gid.x;
    const int row = int(gid.y);

    float s0 = 0.0;
    float s1 = 0.0;
    float s2 = 0.0;
    for (int offset = -radius; offset <= radius; ++offset) {
        const int source = filmReflectEdge(row + offset, int(params.height));
        const uint index = (uint(source) * params.width + gid.x) * 3;
        const float w0 = weights[uint(0 * length + (offset + radius))];
        const float w1 = weights[uint(1 * length + (offset + radius))];
        const float w2 = weights[uint(2 * length + (offset + radius))];
        s0 += src[index] * w0;
        s1 += src[index + 1] * w1;
        s2 += src[index + 2] * w2;
    }
    dst[pixel * 3] = s0;
    dst[pixel * 3 + 1] = s1;
    dst[pixel * 3 + 2] = s2;
}

/// The flag that tells whether a channel uses the Young & van Vliet
/// recursion (one) or the truncated FIR kernel (zero).
///
/// The CPU reference chooses the path of the filter **per channel**: the
/// FIR kernel below `SpatialEffects.smallSigmaMax` (three pixels) and the
/// recursive filter of Young & van Vliet above it.  The two filters are
/// not two roundings of the same thing: they differ by several percents
/// on a blurred field, so the GPU must use the same path as the CPU.
inline float filmIIRFlag(constant FilmBlurParams &params, uint channel) {
    if (channel == 0) {
        return params.iirFlagA;
    }
    if (channel == 1) {
        return params.iirFlagB;
    }
    return params.iirFlagC;
}

/// The coefficients of the Young & van Vliet recursion of a channel.
///
/// The order is `b`, `b1`, `b2` and `b3`: the executable specification of
/// `SpatialEffects.youngVanVlietCoefficients` of the Swift side, which
/// builds them (the CPU reference uses the very same function).
inline float4 filmIIRCoefficients(constant FilmBlurParams &params, uint channel) {
    if (channel == 0) {
        return float4(params.iirB0A, params.iirB1A, params.iirB2A, params.iirB3A);
    }
    if (channel == 1) {
        return float4(params.iirB0B, params.iirB1B, params.iirB2B, params.iirB3B);
    }
    return float4(params.iirB0C, params.iirB1C, params.iirB2C, params.iirB3C);
}

/// The horizontal pass of the Gaussian filter, with the Young & van Vliet
/// recursion.
///
/// The recursion is sequential along the axis of the filter, so the kernel
/// is dispatched with **one thread per row**: the `y` of the thread is the
/// row and its `x` is zero.  The channels whose sigma is below three
/// pixels use the truncated FIR kernel, exactly like the CPU reference.
kernel void filmBlurIIRHorizontal(
    device const float *src [[buffer(0)]],
    device float *dst [[buffer(1)]],
    device const float *weights [[buffer(2)]],
    constant FilmBlurParams &params [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]]
) {
    const uint row = gid.y;
    if (gid.x != 0 || row >= params.height || params.width == 0) {
        return;
    }
    const int width = int(params.width);
    const int radius = min(int(params.radius), FILM_MAX_BLUR_RADIUS);
    const int length = 2 * radius + 1;
    const uint base = row * params.width;

    for (uint channel = 0; channel < 3; ++channel) {
        if (filmIIRFlag(params, channel) > 0.5) {
            // The recursion of Young & van Vliet: the forward sweep, then
            // the backward one.  The boundary is the replication of the
            // edge samples, like the CPU reference.
            const float4 coefficients = filmIIRCoefficients(params, channel);
            const float b = coefficients.x;
            const float b1 = coefficients.y;
            const float b2 = coefficients.z;
            const float b3 = coefficients.w;

            float w1 = src[base * 3 + channel];
            float w2 = w1;
            float w3 = w1;
            for (int column = 0; column < width; ++column) {
                const uint index = (base + uint(column)) * 3 + channel;
                const float value = b * src[index] + b1 * w1 + b2 * w2 + b3 * w3;
                dst[index] = value;
                w3 = w2;
                w2 = w1;
                w1 = value;
            }
            float y1 = dst[(base + uint(width - 1)) * 3 + channel];
            float y2 = y1;
            float y3 = y1;
            for (int step = 0; step < width; ++step) {
                const int column = width - 1 - step;
                const uint index = (base + uint(column)) * 3 + channel;
                const float value = b * dst[index] + b1 * y1 + b2 * y2 + b3 * y3;
                dst[index] = value;
                y3 = y2;
                y2 = y1;
                y1 = value;
            }
        } else {
            // The truncated FIR kernel.
            for (int column = 0; column < width; ++column) {
                float sum = 0.0;
                for (int offset = -radius; offset <= radius; ++offset) {
                    const int source = filmReflectEdge(column + offset, width);
                    const uint index = (base + uint(source)) * 3 + channel;
                    sum += src[index]
                        * weights[uint(channel) * uint(length) + uint(offset + radius)];
                }
                dst[(base + uint(column)) * 3 + channel] = sum;
            }
        }
    }
}

/// The vertical pass of the Gaussian filter, with the Young & van Vliet
/// recursion.
///
/// The kernel is dispatched with **one thread per column**: the `x` of the
/// thread is the column and its `y` is zero.
kernel void filmBlurIIRVertical(
    device const float *src [[buffer(0)]],
    device float *dst [[buffer(1)]],
    device const float *weights [[buffer(2)]],
    constant FilmBlurParams &params [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]]
) {
    const uint column = gid.x;
    if (gid.y != 0 || column >= params.width || params.height == 0) {
        return;
    }
    const int height = int(params.height);
    const int radius = min(int(params.radius), FILM_MAX_BLUR_RADIUS);
    const int length = 2 * radius + 1;
    const uint width = params.width;

    for (uint channel = 0; channel < 3; ++channel) {
        if (filmIIRFlag(params, channel) > 0.5) {
            // The recursion of Young & van Vliet: the forward sweep, then
            // the backward one.  The boundary is the replication of the
            // edge samples, like the CPU reference.
            const float4 coefficients = filmIIRCoefficients(params, channel);
            const float b = coefficients.x;
            const float b1 = coefficients.y;
            const float b2 = coefficients.z;
            const float b3 = coefficients.w;

            float w1 = src[column * 3 + channel];
            float w2 = w1;
            float w3 = w1;
            for (int row = 0; row < height; ++row) {
                const uint index = (uint(row) * width + column) * 3 + channel;
                const float value = b * src[index] + b1 * w1 + b2 * w2 + b3 * w3;
                dst[index] = value;
                w3 = w2;
                w2 = w1;
                w1 = value;
            }
            float y1 = dst[(uint(height - 1) * width + column) * 3 + channel];
            float y2 = y1;
            float y3 = y1;
            for (int step = 0; step < height; ++step) {
                const int row = height - 1 - step;
                const uint index = (uint(row) * width + column) * 3 + channel;
                const float value = b * dst[index] + b1 * y1 + b2 * y2 + b3 * y3;
                dst[index] = value;
                y3 = y2;
                y2 = y1;
                y1 = value;
            }
        } else {
            // The truncated FIR kernel.
            for (int row = 0; row < height; ++row) {
                float sum = 0.0;
                for (int offset = -radius; offset <= radius; ++offset) {
                    const int source = filmReflectEdge(row + offset, height);
                    const uint index = (uint(source) * width + column) * 3 + channel;
                    sum += src[index]
                        * weights[uint(channel) * uint(length) + uint(offset + radius)];
                }
                dst[(uint(row) * width + column) * 3 + channel] = sum;
            }
        }
    }
}

/// The two dimensional convolution of the diffusion filter.
kernel void filmDiffusionFilter(
    device const float *src [[buffer(0)]],
    device float *dst [[buffer(1)]],
    device const float *psf [[buffer(2)]],
    constant FilmBlurParams &params [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= params.width || gid.y >= params.height) {
        return;
    }
    const int radius = min(int(params.radius), FILM_MAX_BLUR_RADIUS);
    const int shape = 2 * radius + 1;
    const uint pixel = gid.y * params.width + gid.x;

    float s0 = 0.0;
    float s1 = 0.0;
    float s2 = 0.0;
    for (int u = 0; u < shape; ++u) {
        const int sourceRow = filmNumpyReflect(int(gid.y) + radius - u, int(params.height));
        for (int v = 0; v < shape; ++v) {
            const int sourceColumn = filmNumpyReflect(int(gid.x) + radius - v, int(params.width));
            const uint index = (uint(sourceRow) * params.width + uint(sourceColumn)) * 3;
            const uint kernelBase = uint(u * shape + v);
            s0 += src[index] * psf[kernelBase];
            s1 += src[index + 1] * psf[kernelBase + uint(shape * shape)];
            s2 += src[index + 2] * psf[kernelBase + uint(2 * shape * shape)];
        }
    }
    const float scatter = params.scatterFraction;
    dst[pixel * 3] = (1.0 - scatter) * src[pixel * 3] + scatter * s0;
    dst[pixel * 3 + 1] = (1.0 - scatter) * src[pixel * 3 + 1] + scatter * s1;
    dst[pixel * 3 + 2] = (1.0 - scatter) * src[pixel * 3 + 2] + scatter * s2;
}

/// The linear combination of two images.
kernel void filmCombine2(
    device const float *a [[buffer(0)]],
    device const float *b [[buffer(1)]],
    device float *dst [[buffer(2)]],
    constant FilmCombineParams &params [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= params.width || gid.y >= params.height) {
        return;
    }
    const uint pixel = gid.y * params.width + gid.x;
    dst[pixel * 3] = params.weightA * a[pixel * 3] + params.weightB * b[pixel * 3];
    dst[pixel * 3 + 1] = params.weightA * a[pixel * 3 + 1]
        + params.weightB * b[pixel * 3 + 1];
    dst[pixel * 3 + 2] = params.weightA * a[pixel * 3 + 2]
        + params.weightB * b[pixel * 3 + 2];
}

/// The linear combination of three images.
kernel void filmCombine3(
    device const float *a [[buffer(0)]],
    device const float *b [[buffer(1)]],
    device const float *c [[buffer(2)]],
    device float *dst [[buffer(3)]],
    constant FilmCombineParams &params [[buffer(4)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= params.width || gid.y >= params.height) {
        return;
    }
    const uint pixel = gid.y * params.width + gid.x;
    dst[pixel * 3] = params.weightA * a[pixel * 3]
        + params.weightB * b[pixel * 3]
        + params.weightC * c[pixel * 3];
    dst[pixel * 3 + 1] = params.weightA * a[pixel * 3 + 1]
        + params.weightB * b[pixel * 3 + 1]
        + params.weightC * c[pixel * 3 + 1];
    dst[pixel * 3 + 2] = params.weightA * a[pixel * 3 + 2]
        + params.weightB * b[pixel * 3 + 2]
        + params.weightC * c[pixel * 3 + 2];
}

/// The combination of the in emulsion scatter.
///
/// `weightA`, `weightB` and `weightC` are the weights of the exponential
/// tail (one per channel) and `weightD` is the amount of the scatter.
kernel void filmScatterCombine(
    device const float *src [[buffer(0)]],
    device const float *core [[buffer(1)]],
    device const float *tail [[buffer(2)]],
    device float *dst [[buffer(3)]],
    constant FilmCombineParams &params [[buffer(4)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= params.width || gid.y >= params.height) {
        return;
    }
    const uint pixel = gid.y * params.width + gid.x;
    const float amount = params.weightD;
    for (uint channel = 0; channel < 3; ++channel) {
        float weight = params.weightA;
        if (channel == 1) {
            weight = params.weightB;
        } else if (channel == 2) {
            weight = params.weightC;
        }
        const float scattered = (1.0 - weight) * core[pixel * 3 + channel]
            + weight * tail[pixel * 3 + channel];
        dst[pixel * 3 + channel] = (1.0 - amount) * src[pixel * 3 + channel]
            + amount * scattered;
    }
}

/// The combination of the back reflection halation.
///
/// `weightA`, `weightB` and `weightC` are the strengths of the halation
/// (one per channel) and `weightD` tells whether the result is renormalised.
kernel void filmHalationCombine(
    device const float *src [[buffer(0)]],
    device const float *blur [[buffer(1)]],
    device float *dst [[buffer(2)]],
    constant FilmCombineParams &params [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= params.width || gid.y >= params.height) {
        return;
    }
    const uint pixel = gid.y * params.width + gid.x;
    const float renormalise = params.weightD;
    for (uint channel = 0; channel < 3; ++channel) {
        float amount = params.weightA;
        if (channel == 1) {
            amount = params.weightB;
        } else if (channel == 2) {
            amount = params.weightC;
        }
        float value = src[pixel * 3 + channel] + amount * blur[pixel * 3 + channel];
        if (renormalise > 0.5) {
            value /= (1.0 + amount);
        }
        dst[pixel * 3 + channel] = value;
    }
}

// MARK: - The kernels of the grain of the negative

/// The particle model of the emulsion layers of the negative.
///
/// The kernel computes the density of the developed grains of every layer
/// of every channel of a pixel: the number of particles of the pixel is
/// drawn from a Poisson distribution, the number of particles that develop
/// from a binomial distribution, and the variates come from the **counter
/// based** generator, so the field does not depend on the order of the
/// pixels.
///
/// The **sampler** of the variates is the one of the parameters: the fast
/// kernels of the upstream (the default) or the exact samplers (the
/// inversion of the cumulative distribution, around the mode of the
/// distribution, which draw from the very same distributions as the SciPy
/// generators of the default path of the upstream).
///
/// The output of the kernel is one image per colour channel, with one
/// channel per emulsion layer: the image of the cyan is
/// `outCyan[pixel * 3 + layer]`, and so on.
kernel void filmGrainLayers(
    device const float *density [[buffer(0)]],
    device float *outCyan [[buffer(1)]],
    device float *outMagenta [[buffer(2)]],
    device float *outYellow [[buffer(3)]],
    device const float *layerCurves [[buffer(4)]],
    device const float *normalisedCurves [[buffer(5)]],
    device const float *layerParameters [[buffer(6)]],
    device const float *uniformity [[buffer(7)]],
    device const uint *seeds [[buffer(8)]],
    constant FilmGrainParams &params [[buffer(9)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= params.width || gid.y >= params.height) {
        return;
    }
    const uint pixel = gid.y * params.width + gid.x;
    const uint samples = params.sampleCount;
    const uint layers = params.layerCount;
    const bool positive = params.positive > 0;
    // The sampler of the variates of the particles.
    const bool exact = params.samplerMode > 0;

    for (uint colour = 0; colour < 3; ++colour) {
        const float value = density[pixel * 3 + colour];

        // The axis of the interpolation: the normalised density curve of
        // the channel, mirrored for a positive emulsion.
        const float x = positive ? -value : value;
        const float first = positive
            ? -normalisedCurves[colour * samples]
            : normalisedCurves[colour * samples];
        const float last = positive
            ? -normalisedCurves[colour * samples + samples - 1]
            : normalisedCurves[colour * samples + samples - 1];

        for (uint layer = 0; layer < layers; ++layer) {
            float layerDensity = 0.0;
            if (x <= first || samples < 2) {
                layerDensity = layerCurves[(0 * 3 + layer) * 3 + colour];
            } else if (x >= last) {
                layerDensity = layerCurves[((samples - 1) * 3 + layer) * 3 + colour];
            } else {
                // The cell of the interpolation: the binary search of the
                // CPU reference (`Numerics.searchSortedRight`), which finds
                // the first sample whose value is above `x`.  The axis of
                // the emulsion ascends in both cases (the density curve of
                // a positive emulsion descends, and it is mirrored), so the
                // search is the one of the CPU reference.
                uint low = 0;
                uint high = samples;
                while (low < high) {
                    const uint middle = (low + high) / 2;
                    const float current = positive
                        ? -normalisedCurves[colour * samples + middle]
                        : normalisedCurves[colour * samples + middle];
                    if (current <= x) {
                        low = middle + 1;
                    } else {
                        high = middle;
                    }
                }
                // `low` is the index of the first sample on the other side
                // of `x`: the cell of the interpolation is the one below
                // it.  The axis of the emulsion ascends (the density curve
                // of a positive emulsion descends, and it is mirrored), so
                // `low` is never zero here.
                const uint cell = low > 0 ? low - 1 : 0;
                const float lowValue = positive
                    ? -normalisedCurves[colour * samples + cell]
                    : normalisedCurves[colour * samples + cell];
                const float highValue = positive
                    ? -normalisedCurves[colour * samples + cell + 1]
                    : normalisedCurves[colour * samples + cell + 1];
                const float step = highValue - lowValue;
                const float t = step != 0.0 ? (x - lowValue) / step : 0.0;
                const float yLow = layerCurves[(cell * 3 + layer) * 3 + colour];
                const float yHigh = layerCurves[((cell + 1) * 3 + layer) * 3 + colour];
                layerDensity = yLow + t * (yHigh - yLow);
            }

            // The minimum density of the layer is added to the densities
            // of the stack, exactly like the upstream does.
            const float minimum = layerParameters[9 + layer * 3 + colour];
            const float planeDensity = layerDensity + minimum;
            const float densityMax = layerParameters[layer * 3 + colour];
            const float nParticles = layerParameters[18 + layer * 3 + colour];
            const float od = layerParameters[27 + layer * 3 + colour];
            const float uniformityValue = uniformity[colour];

            float probability = clamp(planeDensity / densityMax, 1e-6, 1.0 - 1e-6);
            const float saturation = 1.0 - probability * uniformityValue * (1.0 - 1e-6);
            const uint seed = uint(seeds[colour * 3 + layer]);
            int particles = 0;
            int developed = 0;
            if (exact) {
                // The exact samplers: the inversion of the cumulative
                // distribution, around the mode of the distribution.
                particles = filmPoissonExact(
                    nParticles / saturation, seed, pixel, layer, colour
                );
                developed = filmBinomialExact(
                    particles, probability, seed, pixel, layer, colour
                );
            } else {
                // The fast kernels of the upstream (the default).
                particles = filmPoisson(
                    nParticles / saturation, seed, pixel, layer, colour
                );
                developed = filmBinomial(
                    particles, probability, seed, pixel, layer, colour
                );
            }
            const float developedDensity = float(developed) * od * saturation;
            // The output of the kernel is one image per colour channel.
            if (colour == 0) {
                outCyan[pixel * 3 + layer] = developedDensity;
            } else if (colour == 1) {
                outMagenta[pixel * 3 + layer] = developedDensity;
            } else {
                outYellow[pixel * 3 + layer] = developedDensity;
            }
        }
    }
}

/// The sum of the emulsion layers of the grain.
///
/// The three images hold the three emulsion layers of the three colour
/// channels: the channels of the image of the cyan are the layers of the
/// cyan, and so on.  The density of a colour is therefore the sum of the
/// **layers of that colour**, and the sum of the three images (one colour
/// each) would mix the colours and keep a single layer.
kernel void filmGrainSumLayers(
    device const float *cyan [[buffer(0)]],
    device const float *magenta [[buffer(1)]],
    device const float *yellow [[buffer(2)]],
    device float *dst [[buffer(3)]],
    constant FilmPlanParams &params [[buffer(4)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= params.width || gid.y >= params.height) {
        return;
    }
    const uint pixel = gid.y * params.width + gid.x;
    dst[pixel * 3] = cyan[pixel * 3] + cyan[pixel * 3 + 1] + cyan[pixel * 3 + 2];
    dst[pixel * 3 + 1] = magenta[pixel * 3] + magenta[pixel * 3 + 1] + magenta[pixel * 3 + 2];
    dst[pixel * 3 + 2] = yellow[pixel * 3] + yellow[pixel * 3 + 1] + yellow[pixel * 3 + 2];
}

/// The micro structure of the emulsion: the clumping of the dye clouds.
kernel void filmGrainClumping(
    device float *dst [[buffer(0)]],
    constant FilmGrainClumpingParams &params [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= params.width || gid.y >= params.height) {
        return;
    }
    const uint pixel = gid.y * params.width + gid.x;
    for (uint channel = 0; channel < 3; ++channel) {
        dst[pixel * 3 + channel] = filmLognormalFromMeanStd(
            1.0, params.sigma, params.seed, pixel, 0, channel
        );
    }
}

/// The removal of the minimum density of the grain.
kernel void filmGrainFinalize(
    device const float *src [[buffer(0)]],
    device const float *densityMin [[buffer(1)]],
    device float *dst [[buffer(2)]],
    constant FilmPlanParams &params [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= params.width || gid.y >= params.height) {
        return;
    }
    const uint pixel = gid.y * params.width + gid.x;
    for (uint channel = 0; channel < 3; ++channel) {
        dst[pixel * 3 + channel] = src[pixel * 3 + channel] - densityMin[channel];
    }
}

/// The product of two images.
kernel void filmCombineMultiply(
    device const float *a [[buffer(0)]],
    device const float *b [[buffer(1)]],
    device float *dst [[buffer(2)]],
    constant FilmPlanParams &params [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= params.width || gid.y >= params.height) {
        return;
    }
    const uint pixel = gid.y * params.width + gid.x;
    for (uint channel = 0; channel < 3; ++channel) {
        dst[pixel * 3 + channel] = a[pixel * 3 + channel] * b[pixel * 3 + channel];
    }
}

// MARK: - The kernels of the glare of the print

/// The random amount of the glare of the print.
///
/// The field is a lognormal field, drawn from the counter based generator:
/// the three channels hold the same value (the blur of the glare is applied
/// to the three channels at once).
kernel void filmGlareField(
    device float *dst [[buffer(0)]],
    constant FilmGlareParams &params [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= params.width || gid.y >= params.height) {
        return;
    }
    const uint pixel = gid.y * params.width + gid.x;
    const float value = filmLognormalFromMeanStd(
        params.mean, params.std, params.seed, pixel, 0, 0
    );
    dst[pixel * 3] = value;
    dst[pixel * 3 + 1] = value;
    dst[pixel * 3 + 2] = value;
}

/// The addition of the glare to the tristimulus values of the scan.
kernel void filmGlareApply(
    device const float *xyzIn [[buffer(0)]],
    device const float *amount [[buffer(1)]],
    device const float *illuminantXYZ [[buffer(2)]],
    device float *dst [[buffer(3)]],
    constant FilmPlanParams &params [[buffer(4)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= params.width || gid.y >= params.height) {
        return;
    }
    const uint pixel = gid.y * params.width + gid.x;
    const float value = amount[pixel * 3] / 100.0;
    for (uint component = 0; component < 3; ++component) {
        dst[pixel * 3 + component] = xyzIn[pixel * 3 + component]
            + value * illuminantXYZ[component];
    }
}
