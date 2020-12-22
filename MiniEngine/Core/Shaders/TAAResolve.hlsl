///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Copyright (c) 2019-2020, Intel Corporation
// Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated 
// documentation files (the "Software"), to deal in the Software without restriction, including without limitation 
// the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
// permit persons to whom the Software is furnished to do so, subject to the following conditions:
// The above copyright notice and this permission notice shall be included in all copies or substantial portions of 
// the Software.
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO
// THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE 
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, 
// TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE 
// SOFTWARE.
///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

// These dependencies come from the MiniEngine
#include "PixelPacking_Velocity.hlsli"
#include "PixelPacking_R11G11B10.hlsli"
#include "TemporalRS.hlsli"

///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
//
// Defines to toggle HW features
//
///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

// Whether to use real 16-bit floats
// Use only with DXIL with SM6.2 and "-enable-16bit-types" as a compiler option
#ifndef USE_FP16
#define USE_FP16 0
#endif

typedef float  fp32_t;
typedef float2 fp32_t2;
typedef float3 fp32_t3;
typedef float4 fp32_t4;

#if 0 == USE_FP16
typedef float  fp16_t;
typedef float2 fp16_t2;
typedef float3 fp16_t3;
typedef float4 fp16_t4;

typedef int  i16_t;
typedef int2 i16_t2;
typedef int3 i16_t3;
typedef int4 i16_t4;

typedef uint  ui16_t;
typedef uint2 ui16_t2;
typedef uint3 ui16_t3;
typedef uint4 ui16_t4;
#else
typedef float16_t  fp16_t;
typedef float16_t2 fp16_t2;
typedef float16_t3 fp16_t3;
typedef float16_t4 fp16_t4;

typedef int16_t  i16_t;
typedef int16_t2 i16_t2;
typedef int16_t3 i16_t3;
typedef int16_t4 i16_t4;

typedef uint16_t  ui16_t;
typedef uint16_t2 ui16_t2;
typedef uint16_t3 ui16_t3;
typedef uint16_t4 ui16_t4;
#endif

// Whether to use thread group shared memory
#ifndef USE_TGSM
#define USE_TGSM 1
#endif

///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
//
// Params from the host app
//
///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

// in current MiniEngine's format
Texture2D<packed_velocity_t> VelocityBuffer : register( t0 );

// Current colour buffer - rgb used
Texture2D<fp16_t3> ColourTexture : register( t1 );

// Stored temporal antialiased pixel - .a should be sufficient enough to handle weight stored as float [0.5f, 1.f)
Texture2D<fp32_t4> HistoryTexture : register( t2 );

// Current linear depth buffer - used only when USE_DEPTH_THRESHOLD is set
Texture2D<fp16_t> DepthBuffer : register( t3 );

// Previous linear frame depth buffer - used only when USE_DEPTH_THRESHOLD is set
Texture2D<fp16_t> PrvDepthBuffer : register( t4 );

// Antialiased colour buffer (used in a next frame as the HistoryTexture)
RWTexture2D<fp16_t4> OutTexture : register( u0 );

// Samplers
SamplerState MinMagLinearMipPointClamp : register( s0 );
SamplerState MinMagMipPointClamp : register( s1 );

// Constant buffer
struct FTAAResolve
{
    float4      Resolution;         //width, height, 1/width, 1/height
    float2      Jitter;
    uint        FrameNumber;
    uint        DebugFlags;         // AllowLongestVelocityVector | AllowNeighbourhoodSampling | AllowYCoCg | AllowVarianceClipping | AllowBicubicFilter | AllowDepthThreshold | MarkNoHistoryPixels
};

cbuffer CBMeshConstants : register( b1 )
{
    FTAAResolve CBData;
};

///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
//
// Defines to tweak in/out formats
//
///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

// Use Tone-mapped values only for final lerp
#ifndef USE_TONE_MAPPED_COLOUR_ONLY_IN_FINAL
#define USE_TONE_MAPPED_COLOUR_ONLY_IN_FINAL 0
#endif

// History buffer is stored as tone mapped
#ifndef KEEP_HISTORY_TONE_MAPPED
#define KEEP_HISTORY_TONE_MAPPED ( 1 && ( 0 == USE_TONE_MAPPED_COLOUR_ONLY_IN_FINAL ) )
#endif

// Enabled tweaking from host app, uses CBData.DebugFlags to toggle features
#ifndef ENABLE_DEBUG
#define ENABLE_DEBUG 1
#endif

///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
//
// Defines to tweak quality options (and performance)
//
///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

// Best quality settings:
//#define USE_DEPTH_THRESHOLD 1
//#define VARIANCE_BBOX_NUMBER_OF_SAMPLES USE_SAMPLES_9
//#define USE_VARIANCE_CLIPPING 2
//#define USE_YCOCG_SPACE 1
//#define ALLOW_NEIGHBOURHOOD_SAMPLING 1
//#define USE_BICUBIC_FILTER 1
//#define USE_LONGEST_VELOCITY_VECTOR 1 //greatly improves edges AA quality, but may introduce blur - app choice

// High quality settings that should handle most cases
//#define USE_DEPTH_THRESHOLD 1
//#define VARIANCE_BBOX_NUMBER_OF_SAMPLES USE_SAMPLES_5
//#define USE_VARIANCE_CLIPPING 1
//#define USE_YCOCG_SPACE 1
//#define ALLOW_NEIGHBOURHOOD_SAMPLING 1
//#define USE_BICUBIC_FILTER 1
//#define USE_LONGEST_VELOCITY_VECTOR 1 //greatly improves edges AA quality, but may introduce blur - app choice

// Gen9 (skull canyon) / Gen11 settings
//#define USE_DEPTH_THRESHOLD 0
//#define VARIANCE_BBOX_NUMBER_OF_SAMPLES USE_SAMPLES_5
//#define USE_VARIANCE_CLIPPING 1
//#define USE_YCOCG_SPACE 0
//#define ALLOW_NEIGHBOURHOOD_SAMPLING 0
//#define USE_BICUBIC_FILTER 0
//#define USE_LONGEST_VELOCITY_VECTOR 0

// MIN - MAX variance gamma, it's lerped using a velocity confidence factor
#define MIN_VARIANCE_GAMMA 0.75f // under motion
#define MAX_VARIANCE_GAMMA 2.f // no motion

// MAX_T to ensure colour stability when using USE_VARIANCE_CLIPPING option 2 
#define VARIANCE_INTERSECTION_MAX_T 100

// Difference between current depth buffer and previous depth buffer to consider a pixel as an edge
#define DEPTH_DIFF fp16_t( 0.002f )

// Mark pixel as no-valid-history when depth value between current and previous frames goes above a threshold
#ifndef USE_DEPTH_THRESHOLD
#define USE_DEPTH_THRESHOLD 1
#endif

// Definition of number of samples
#define USE_SAMPLES_5 0
#define USE_SAMPLES_9 1

// How many samples for variance clipping, 5 is faster and usually gives expected results. 9 should be used in scenes when there's shimmering on edges between dark and bright colours
#ifndef VARIANCE_BBOX_NUMBER_OF_SAMPLES
#define VARIANCE_BBOX_NUMBER_OF_SAMPLES USE_SAMPLES_9
#endif

// Use variance clipping: 0 - no clipping, 1 - clamp to AABB min/max, 2 - use colour intersection
// 1 is sufficient for most cases
#ifndef USE_VARIANCE_CLIPPING
#define USE_VARIANCE_CLIPPING 1 //0 - no clipping, 1 - use min/max clipping, 2 - use colour intersection
#endif

// Use YCoCg colour space when the Variance Clipping is enabled
#ifndef USE_YCOCG_SPACE
#define USE_YCOCG_SPACE 1
#endif

// Use neighbourhood sampling for pixels that don't have valid history
#ifndef ALLOW_NEIGHBOURHOOD_SAMPLING
#define ALLOW_NEIGHBOURHOOD_SAMPLING 1
#endif

// Allow to use bicubic filter for better quality of the history colour
#ifndef USE_BICUBIC_FILTER
#define USE_BICUBIC_FILTER 1
#endif

// Sample neighbourhood and select the longest vector - greatly improves quality on edges but may introduce more blur
#ifndef USE_LONGEST_VELOCITY_VECTOR
#define USE_LONGEST_VELOCITY_VECTOR 1
#endif

// How many samples to use for finding the longest velocity vector 
#ifndef LONGEST_VELOCITY_VECTOR_SAMPLES
#define LONGEST_VELOCITY_VECTOR_SAMPLES USE_SAMPLES_9
#endif

// Difference in pixels for velocity after which the pixel is marked as no-history
#ifndef FRAME_VELOCITY_IN_PIXELS_DIFF
#define FRAME_VELOCITY_IN_PIXELS_DIFF 128   //valid for 1920x1080
#endif

#ifndef NEEDS_EDGE_DETECTION
#define NEEDS_EDGE_DETECTION ( ( 0 == USE_BICUBIC_FILTER ) && ( 0 == USE_LONGEST_VELOCITY_VECTOR ) )
#endif

///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
//
// Implementation
//
///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

#define NUM_THREADS_X 8
#define NUM_THREADS_Y 8

#if 1 == USE_TGSM
#define FRAME_COLOUR_ST i16_t
#define TGSM_CACHE_WIDTH ( NUM_THREADS_X + 2 )   //+2 for border
#define TGSM_CACHE_HEIGHT ( NUM_THREADS_Y + 2 )  //+2 for border
#define MAKEOFFSET( x, y ) FRAME_COLOUR_ST( y * TGSM_CACHE_WIDTH + x )
#else
#define FRAME_COLOUR_ST i16_t2
#define MAKEOFFSET( x, y ) FRAME_COLOUR_ST( x, y )
#endif

fp16_t4 GetHistory( fp32_t2 inHistoryUV, fp32_t2 inHistoryST, bool inIsOnEdge );
fp16_t3 GetCurrentColourNeighbourhood( fp16_t3 inCurrentColour, FRAME_COLOUR_ST inScreenST );
//fp16_t3 GetCurrentColourNeighbourhood( fp16_t3 inCurrentColour, i16_t2 inScreenST );
fp16_t3 ClipHistoryColour( fp16_t3 inCurrentColour, fp16_t3 inHistoryColour, FRAME_COLOUR_ST inScreenST, fp16_t inVarianceGamma, uint inFrameNumber );
fp16_t3 GetVelocity( i16_t2 inScreenST );
fp16_t3 GetCurrentColour( FRAME_COLOUR_ST inST );
fp16_t GetCurrentDepth( fp32_t2 inUV, out bool outIsOnEdge );
fp16_t GetDepthConfidenceFactor( ui16_t2 inST, fp16_t3 inVelocity, fp16_t inCurrentFrameDepth, bool inIsOnEdge );
fp16_t4 GetFinalColour( fp16_t3 inCurrentColour, fp16_t3 inHistoryColour, fp16_t inWeight );
float2 GetUV( float2 inST );
void StoreCurrentColourToSLM( ui16_t2 inGroupStartThread, i16_t2 inGroupThreadID );

float3 DebugColourNoHistory();

// The root signature comes from the MiniEngine
[RootSignature( Temporal_RootSig )]
[numthreads( NUM_THREADS_X, NUM_THREADS_Y, 1 )]
void main( uint3 inDispatchIdx : SV_DispatchThreadID, uint3 inGroupID : SV_GroupID, uint3 inGroupThreadID : SV_GroupThreadID )
{
    const ui16_t2 screenST = ui16_t2( inDispatchIdx.xy );

    const ui16_t2 groupStartingThread = ui16_t2( inGroupID.xy ) * ui16_t2( NUM_THREADS_X, NUM_THREADS_Y );
    StoreCurrentColourToSLM( groupStartingThread, i16_t2( inGroupThreadID.xy ) );
#if 1 == USE_TGSM
    const FRAME_COLOUR_ST groupST = MAKEOFFSET( ( inGroupThreadID.x + 1 ), ( inGroupThreadID.y + 1 ) );
#else
    const FRAME_COLOUR_ST groupST = screenST;
#endif

    // sample current colour
    const fp16_t3 currentFrameColour = GetCurrentColour( groupST );

    // to mark edges - edges may get different filtering
    bool isOnEdge = false;

    // get velocity
    const fp16_t3 velocity = GetVelocity( screenST );

    // calculate confidence factor based on the velocity of current pixel, everything moving faster than FRAME_VELOCITY_IN_PIXELS_DIFF frame-to-frame will be marked as no-history
    const fp16_t velocityConfidenceFactor = saturate( fp16_t( 1.f ) - length( velocity.xy ) / FRAME_VELOCITY_IN_PIXELS_DIFF );

    // prev frame ST and UV
    const float2 prevFrameScreenST = screenST + fp32_t2( velocity.xy );
    const float2 prevFrameScreenUV = GetUV( prevFrameScreenST );

    // get current depth and ...
    const fp16_t depth = GetCurrentDepth( GetUV( screenST ), isOnEdge );

    // get depth confidence factor, larger then 0, assume the history is valid
    const fp16_t depthDiffFactor = GetDepthConfidenceFactor( screenST, velocity, depth, isOnEdge );

    // do we have a valid history?
    const fp16_t uvWeight = fp16_t( ( all( prevFrameScreenUV >= float2( 0.f, 0.f ) ) && all( prevFrameScreenUV < float2( 1.f, 1.f ) ) ) ? 1.0f : 0.f );
    const bool hasValidHistory = ( velocityConfidenceFactor * depthDiffFactor * uvWeight ) > 0.f;
    fp16_t4 finalColour = fp16_t4( 1.f.xxxx );

    if ( true == hasValidHistory )
    {
        // sample history
        fp16_t4 rawHistoryColour = fp16_t4( GetHistory( prevFrameScreenUV, prevFrameScreenST, isOnEdge ) );

        // lerp between MIN and MAX variance gamma to ensure when no motion specular highlights not cut by the variance clipping
        const fp16_t varianceGamma = fp16_t( lerp( MIN_VARIANCE_GAMMA, MAX_VARIANCE_GAMMA, velocityConfidenceFactor * velocityConfidenceFactor ) );

        // clip history colour to the bounding box of expected colours based on the current frame colour
        const fp16_t3 historyColour = ClipHistoryColour( currentFrameColour, rawHistoryColour.xyz, groupST, varianceGamma, 0 );

        // final weight for lerp between the current frame colour and the temporal history colour
        const fp16_t weight = rawHistoryColour.a * velocityConfidenceFactor * depthDiffFactor;

        finalColour = fp16_t4( GetFinalColour( currentFrameColour, historyColour, weight ) );
    }

    else
    {
        const float3 filteredCurrentColourNeightbourhood = GetCurrentColourNeighbourhood( currentFrameColour, groupST ) * DebugColourNoHistory();
        finalColour = fp16_t4( filteredCurrentColourNeightbourhood, 0.5f );
    }

    // Store the final pixel colour
    OutTexture[ inDispatchIdx.xy ] = finalColour.rgba;
}

///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
//
// Helper functions
//
///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

// YCoCg colour space
bool AllowYCoCg();

fp16_t3 RGB2YCoCg( fp16_t3 inRGB )
{
    //Y = R / 4 + G / 2 + B / 4
    //Co = R / 2 - B / 2
    //Cg = -R / 4 + G / 2 - B / 4
    if ( AllowYCoCg() )
    {
        const fp16_t y = dot( inRGB, fp16_t3( 0.25f, 0.5f, 0.25f ) );
        const fp16_t co = dot( inRGB, fp16_t3( 0.5f, 0.f, -0.5f ) );
        const fp16_t cg = dot( inRGB, fp16_t3( -0.25f, 0.5f, -0.25f ) );
        return fp16_t3( y, co, cg );
    }

    else
    {
        return inRGB;
    }
}

fp16_t3 YCoCg2RGB( fp16_t3 inYCoCg )
{
    //R = Y + Co - Cg
    //G = Y + Cg
    //B = Y - Co - Cg
    if ( AllowYCoCg() )
    {
        const fp16_t r = dot( inYCoCg, fp16_t3( 1.f, 1.f, -1.f ) );
        const fp16_t g = dot( inYCoCg, fp16_t3( 1.f, 0.f, 1.f ) );
        const fp16_t b = dot( inYCoCg, fp16_t3( 1.f, -1.f, -1.f ) );
        return fp16_t3( r, g, b );
    }

    else
    {
        return inYCoCg;
    }
}

// Reinhard tone mapper
fp16_t LuminanceRec709( fp16_t3 inRGB )
{
    return dot( inRGB, fp16_t3( 0.2126f, 0.7152f, 0.0722f ) );
}

fp16_t3 Reinhard( fp16_t3 inRGB )
{
    return inRGB / ( fp16_t( 1.f ) + LuminanceRec709( inRGB ) );
}

fp16_t3 InverseReinhard( fp16_t3 inRGB )
{
    return inRGB / ( fp16_t( 1.f ) - LuminanceRec709( inRGB ) );
}

#if 1 == USE_TGSM
groupshared uint TGSM_Colour[ TGSM_CACHE_WIDTH * TGSM_CACHE_HEIGHT ]; // 8 x 8 + 1 pixel border that gives 10 x 10
#endif

// Precache current colours to SLM
void StoreCurrentColourToSLM( ui16_t2 inGroupStartThread, i16_t2 inGroupThreadID  )
{
#if 1 == USE_TGSM
    if ( ( inGroupThreadID.x < 5 ) && ( inGroupThreadID.y < 5 ) )
    {
        const ui16_t2 indexMul2 = ui16_t2( inGroupThreadID.xy ) * ui16_t2( 2, 2 );

        const ui16_t linearTGSMIndexOfTopLeft = MAKEOFFSET( indexMul2.x, indexMul2.y );

        const i16_t2 stForTexture = i16_t2( inGroupStartThread ) + i16_t2( indexMul2 ) - i16_t2( 1, 1 );
        const fp32_t2 uv = ( fp32_t2( stForTexture + 0.5f ) ) * CBData.Resolution.zw;
        const fp16_t4 reds = ColourTexture.GatherRed( MinMagLinearMipPointClamp, uv );
        const fp16_t4 greens = ColourTexture.GatherGreen( MinMagLinearMipPointClamp, uv );
        const fp16_t4 blues = ColourTexture.GatherBlue( MinMagLinearMipPointClamp, uv );

#if 0 == USE_TONE_MAPPED_COLOUR_ONLY_IN_FINAL
        TGSM_Colour[ linearTGSMIndexOfTopLeft                           ] = Pack_R11G11B10_FLOAT( Reinhard( fp16_t3( reds.w, greens.w, blues.w ) ) );
        TGSM_Colour[ linearTGSMIndexOfTopLeft + 1                       ] = Pack_R11G11B10_FLOAT( Reinhard( fp16_t3( reds.z, greens.z, blues.z ) ) );
        TGSM_Colour[ linearTGSMIndexOfTopLeft + TGSM_CACHE_WIDTH        ] = Pack_R11G11B10_FLOAT( Reinhard( fp16_t3( reds.x, greens.x, blues.x ) ) );
        TGSM_Colour[ linearTGSMIndexOfTopLeft + TGSM_CACHE_WIDTH + 1    ] = Pack_R11G11B10_FLOAT( Reinhard( fp16_t3( reds.y, greens.y, blues.y ) ) );
#else
        TGSM_Colour[ linearTGSMIndexOfTopLeft                           ] = Pack_R11G11B10_FLOAT( fp16_t3( reds.w, greens.w, blues.w ) );
        TGSM_Colour[ linearTGSMIndexOfTopLeft + 1                       ] = Pack_R11G11B10_FLOAT( fp16_t3( reds.z, greens.z, blues.z ) );
        TGSM_Colour[ linearTGSMIndexOfTopLeft + TGSM_CACHE_WIDTH        ] = Pack_R11G11B10_FLOAT( fp16_t3( reds.x, greens.x, blues.x ) );
        TGSM_Colour[ linearTGSMIndexOfTopLeft + TGSM_CACHE_WIDTH + 1    ] = Pack_R11G11B10_FLOAT( fp16_t3( reds.y, greens.y, blues.y ) );
#endif
    }
    GroupMemoryBarrierWithGroupSync();
#endif
}

// Returns current frame colour, apply ToneMapper if needed
fp16_t3 GetCurrentColour( FRAME_COLOUR_ST inST )
{
#if 1 == USE_TGSM
    return fp16_t3( Unpack_R11G11B10_FLOAT( TGSM_Colour[ inST ] ) );
#else
    inST = clamp( inST, i16_t2( 0, 0 ), i16_t2( CBData.Resolution.xy ) );
    const fp16_t3 colour = ColourTexture.Load( ui16_t3( inST, 0 ) ).rgb;
#if 0 == USE_TONE_MAPPED_COLOUR_ONLY_IN_FINAL
    return Reinhard( colour );
#else
    return colour;
#endif
#endif
}

// Performs ray-aabb intersection 
fp16_t3 ClipToAABB( fp16_t3 inHistoryColour, fp16_t3 inCurrentColour, fp32_t3 inBBCentre, fp32_t3 inBBExtents )
{
    const fp16_t3 direction = inCurrentColour - inHistoryColour;

    // calculate intersection for the closest slabs from the center of the AABB in HistoryColour direction
    const fp32_t3 intersection = ( ( inBBCentre - sign( direction ) * inBBExtents ) - inHistoryColour ) / direction;

    // clip unexpected T values
    const fp32_t3 possibleT = intersection >= 0.0f.xxx ? intersection : VARIANCE_INTERSECTION_MAX_T + 1.f;
    const fp32_t t = min( VARIANCE_INTERSECTION_MAX_T, min( possibleT.x, min( possibleT.y, possibleT.z ) ) );

    // final history colour
    return fp16_t3( t < VARIANCE_INTERSECTION_MAX_T ? inHistoryColour + direction * t : inHistoryColour );
}

// Performs VarianceClipping
// Following Marco Salvi's paper (idea + implementation) from GDC16: An excursion in Temporal Supersampling
bool AllowVarianceClipping();

fp16_t3 ClipHistoryColour( fp16_t3 inCurrentColour, fp16_t3 inHistoryColour, FRAME_COLOUR_ST inScreenST, fp16_t inVarianceGamma, uint inFrameNumber )
{
    fp16_t3 toReturn = inHistoryColour;

    if ( AllowVarianceClipping() )
    {
#if VARIANCE_BBOX_NUMBER_OF_SAMPLES == USE_SAMPLES_9
        inFrameNumber = 0;
        // 9 samples in '+' and 'x'
        const FRAME_COLOUR_ST offsets[ 1 ][ 8 ] = { MAKEOFFSET( -1, -1 ), MAKEOFFSET( -1, 0 ), MAKEOFFSET( -1, 1 ), MAKEOFFSET( 0, 1 ), MAKEOFFSET( 1, 1 ), MAKEOFFSET( 1, 0 ), MAKEOFFSET( 1, -1 ), MAKEOFFSET( 0, -1 ) };
        const ui16_t iteratorMax = 8;
        const fp32_t rcpDivider = 1.f / 9.f;
        inFrameNumber = 0;
#else
        // 5 samples, current '+' is used. I had an idea to remove shimmering using rotating sampling pattern but I don't have good test case...
        const FRAME_COLOUR_ST offsets[ 2 ][ 4 ] = { { MAKEOFFSET( -1, 0 ), MAKEOFFSET( 0, 1 ), MAKEOFFSET( 1, 0 ), MAKEOFFSET( 0, -1 ) }, { MAKEOFFSET( -1, -1 ), MAKEOFFSET( 1, -1 ), MAKEOFFSET( 1, 1 ), MAKEOFFSET( -1, 1 ) } };
        const ui16_t iteratorMax = 4;
        const fp32_t rcpDivider = 0.2f;
#endif
        // calcluate mean value (mean) and standard deviation (variance)
        const fp32_t3 currentColourInYCoCg = RGB2YCoCg( inCurrentColour );

        fp32_t3 moment1 = currentColourInYCoCg;
        fp32_t3 moment2 = currentColourInYCoCg * currentColourInYCoCg;
        [unroll]
        for ( ui16_t i = 0; i < iteratorMax; ++i )
        {
            const FRAME_COLOUR_ST newST = inScreenST + offsets[ inFrameNumber ][ i ];
            const fp32_t3 newColour = RGB2YCoCg( GetCurrentColour( newST ) );
            moment1 += newColour;
            moment2 += newColour * newColour;
        }

        // mean is the center of AABB and variance (standard deviation) is its extents
        const fp32_t3 mean = moment1 * rcpDivider;
        const fp32_t3 variance = sqrt( moment2 * rcpDivider - mean * mean ) * inVarianceGamma;

#if 1 == USE_VARIANCE_CLIPPING
        // clamp to AABB min/max
        const fp16_t3 minC = fp16_t3( mean - variance );
        const fp16_t3 maxC = fp16_t3( mean + variance );

        toReturn = clamp( inHistoryColour, YCoCg2RGB( minC ), YCoCg2RGB( maxC ) );
#else
        // do the colour/AABB intersection
        toReturn = YCoCg2RGB( ClipToAABB( RGB2YCoCg( inHistoryColour ), fp16_t3( currentColourInYCoCg ), mean, variance ) );
#endif
    }

    return toReturn;
}

// 5-tap bicubic sampling - taken from MiniEngine by MSFT, few things changed (minor) to fit my approach
fp16_t4 BicubicSampling5( fp32_t2 inHistoryST )
{
    const fp32_t2 rcpResolution = CBData.Resolution.zw;
    const fp32_t2 fractional = frac( inHistoryST );
    const fp32_t2 uv = ( floor( inHistoryST ) + fp32_t2( 0.5f, 0.5f ) ) * rcpResolution;

    // 5-tap bicubic sampling (for Hermite/Carmull-Rom filter) -- (approximate from original 16->9-tap bilinear fetching) 
    const fp16_t2 t = fp16_t2( fractional );
    const fp16_t2 t2 = fp16_t2( fractional * fractional );
    const fp16_t2 t3 = fp16_t2( fractional * fractional * fractional );
    const fp16_t s = fp16_t( 0.5h );
    const fp16_t2 w0 = -s * t3 + fp16_t( 2.f ) * s * t2 - s * t;
    const fp16_t2 w1 = ( fp16_t( 2.f ) - s ) * t3 + ( s - fp16_t( 3.f ) ) * t2 + fp16_t( 1.f );
    const fp16_t2 w2 = ( s - fp16_t( 2.f ) ) * t3 + ( 3 - fp16_t( 2.f ) * s ) * t2 + s * t;
    const fp16_t2 w3 = s * t3 - s * t2;
    const fp16_t2 s0 = w1 + w2;
    const fp32_t2 f0 = w2 / ( w1 + w2 );
    const fp32_t2 m0 = uv + f0 * rcpResolution;
    const fp32_t2 tc0 = uv - 1.f * rcpResolution;
    const fp32_t2 tc3 = uv + 2.f * rcpResolution;

    const fp16_t4 A = fp16_t4( HistoryTexture.SampleLevel( MinMagLinearMipPointClamp, fp32_t2( m0.x, tc0.y ), 0 ) );
    const fp16_t4 B = fp16_t4( HistoryTexture.SampleLevel( MinMagLinearMipPointClamp, fp32_t2( tc0.x, m0.y ), 0 ) );
    const fp16_t4 C = fp16_t4( HistoryTexture.SampleLevel( MinMagLinearMipPointClamp, fp32_t2( m0.x, m0.y ), 0 ) );
    const fp16_t4 D = fp16_t4( HistoryTexture.SampleLevel( MinMagLinearMipPointClamp, fp32_t2( tc3.x, m0.y ), 0 ) );
    const fp16_t4 E = fp16_t4( HistoryTexture.SampleLevel( MinMagLinearMipPointClamp, fp32_t2( m0.x, tc3.y ), 0 ) );
    const fp16_t4 color = ( fp16_t( 0.5f ) * ( A + B ) * w0.x + A * s0.x + fp16_t( 0.5f ) * ( A + B ) * w3.x ) * w0.y + ( B * w0.x + C * s0.x + D * w3.x ) * s0.y + ( fp16_t( 0.5f ) * ( B + E ) * w0.x + E * s0.x + fp16_t( 0.5f ) * ( D + E ) * w3.x ) * w3.y;
    return color;
}

bool AllowLongestVelocityVector();
bool AllowBicubicFilter();

// Sample history, if Longest Velocity Vector is used then entire history is sampled using selected algorithm (Bicubic or Bilinear).
// Bilinear gets entire image blurrier but looks better on edges if Longest Velocity Vector is _not_ enabled (and it's faster).
fp16_t4 GetHistory( fp32_t2 inHistoryUV, fp32_t2 inHistoryST, bool inIsOnEdge )
{
    fp16_t4 toReturn = 0.f;
    const bool useBilinearOnEdges = ( false == AllowLongestVelocityVector() );
    const bool useBicubic = ( true == AllowLongestVelocityVector() ) || ( ( false == inIsOnEdge ) && ( true == useBilinearOnEdges ) );

    if ( AllowBicubicFilter() && ( true == useBicubic ) )
    {
        toReturn = BicubicSampling5( inHistoryST );
    }

    else
    {
        toReturn = fp16_t4( HistoryTexture.SampleLevel( MinMagLinearMipPointClamp, inHistoryUV, 0 ) );
    }

#if ( 0  == KEEP_HISTORY_TONE_MAPPED ) && ( 0 == USE_TONE_MAPPED_COLOUR_ONLY_IN_FINAL )
    toReturn = fp16_t4( Reinhard( toReturn.rgb ), toReturn.a );
#endif
    return toReturn;
}

// get velocity and expected depth diff for the current pixel
fp16_t3 GetVelocity( i16_t2 inScreenST )
{
    fp32_t3 toReturn = UnpackVelocity( VelocityBuffer[ inScreenST ] );

    if ( AllowLongestVelocityVector() )
    {
#if LONGEST_VELOCITY_VECTOR_SAMPLES == USE_SAMPLES_9
        const i16_t2 offsets[ 8 ] = { i16_t2( -1, -1 ), i16_t2( -1, 0 ), i16_t2( -1, 1 ), i16_t2( 0, 1 ), i16_t2( 1, 1 ), i16_t2( 1, 0 ), i16_t2( 1, -1 ), i16_t2( 0, -1 ) };
        const ui16_t numberOfSamples = 8;
#else
        const i16_t2 offsets[ 4 ] = { i16_t2( -1, -1 ), i16_t2( -1, 1 ), i16_t2( 1, 1 ), i16_t2( 1, -1 ) };
        const ui16_t numberOfSamples = 4;
#endif

        fp32_t currentLengthSq = dot( toReturn.xy, toReturn.xy );
        [unroll]
        for ( uint i = 0; i < numberOfSamples; ++i )
        {
            const fp32_t3 velocity = UnpackVelocity( VelocityBuffer[ inScreenST + offsets[ i ] ] );
            const fp32_t sampleLengthSq = dot( velocity.xy, velocity.xy );
            if ( sampleLengthSq > currentLengthSq )
            {
                toReturn = velocity;
                currentLengthSq = sampleLengthSq;
            }
        }
    }

    return fp16_t3( toReturn );
}

// Samples neighbourhood in 'x' patter for no-history pixel
bool AllowNeighbourhoodSampling();

fp16_t3 GetCurrentColourNeighbourhood( fp16_t3 inCurrentColour, FRAME_COLOUR_ST inScreenST )
{
    const FRAME_COLOUR_ST offsets[ 4 ] = { MAKEOFFSET( -1, -1 ), MAKEOFFSET( -1, 1 ), MAKEOFFSET( 1, 1 ), MAKEOFFSET( 1, -1 ) };

    fp16_t3 accColour = inCurrentColour;
    [unroll]
    for ( ui16_t i = 0; i < 4; ++i )
    {
        const FRAME_COLOUR_ST newST = inScreenST + offsets[ i ];
        accColour += GetCurrentColour( newST );
    }

    accColour = accColour * fp16_t( 0.2f );
    return accColour;
}

// Min and Max of depth values helpers
fp16_t MaxOf( fp16_t4 inDepths ) { return max( max( inDepths.x, inDepths.y ), max( inDepths.z, inDepths.w ) ); }
fp16_t MinOf( fp16_t4 inDepths ) { return min( min( inDepths.x, inDepths.y ), min( inDepths.z, inDepths.w ) ); }

// Get current depth and checke whether it's on the edge
fp16_t GetCurrentDepth( fp32_t2 inUV, out bool outIsOnEdge )
{
    const fp16_t4 depths = DepthBuffer.Gather( MinMagLinearMipPointClamp, inUV );
    const fp16_t minDepth = MinOf( depths );
#if 1 == NEEDS_EDGE_DETECTION
    const fp16_t maxDepth = MaxOf( depths );
    outIsOnEdge = abs( maxDepth - minDepth ) > DEPTH_DIFF ? true : false;
#else
    outIsOnEdge = false;
#endif
    return minDepth;
}

// Previous depth
fp16_t GetPreviousDepth( fp32_t2 inUV )
{
    return MaxOf( PrvDepthBuffer.Gather( MinMagLinearMipPointClamp, inUV ) ) + fp16_t( 0.001f );
}

// Helper to convert ST coords to UV
float2 GetUV( float2 inST )
{
    return ( inST + 0.5f.xx ) * CBData.Resolution.zw;
}

// Calculate depth confidence factor using the current and previous depth buffers
bool AllowDepthThreshold();

fp16_t GetDepthConfidenceFactor( ui16_t2 inST, fp16_t3 inVelocity, fp16_t inCurrentFrameDepth, bool inIsOnEdge )
{
    fp16_t depthDiffFactor = fp16_t( 1.f );
    if ( AllowDepthThreshold() )
    {
        const fp16_t prevDepth = GetPreviousDepth( GetUV( inST + inVelocity.xy + CBData.Jitter.xy ) );
        const fp16_t currentDepth = inCurrentFrameDepth + inVelocity.z;
#if 1 == NEEDS_EDGE_DETECTION
        depthDiffFactor = false == inIsOnEdge ? step( currentDepth, prevDepth ) : depthDiffFactor;
#else
        depthDiffFactor = step( currentDepth, prevDepth );
#endif
    }

    return depthDiffFactor;
}

// Peform final lerp between the current frame colour and the temporal history colour
fp16_t4 GetFinalColour( fp16_t3 inCurrentColour, fp16_t3 inHistoryColour, fp16_t inWeight )
{
    // Calculate a new confidence factor for the next frame. The value is between [0.5f, 1.f).
    const fp16_t newWeight = saturate( fp16_t( 1.f ) / ( fp16_t( 2.f ) - inWeight ) );
#if 0 == USE_TONE_MAPPED_COLOUR_ONLY_IN_FINAL
    fp16_t4 toReturn = fp16_t4( lerp( inCurrentColour, inHistoryColour, inWeight ), newWeight );
#if 0 == KEEP_HISTORY_TONE_MAPPED
    toReturn = fp16_t4( InverseReinhard( toReturn.rgb ), toReturn.a );
#endif
#else
    fp16_t4 toReturn = fp16_t4( InverseReinhard( lerp( Reinhard( inCurrentColour ), Reinhard( inHistoryColour ), inWeight ) ), newWeight );
#endif
    return toReturn;
}

///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
//
// Debug functions
//
//    uint        DebugFlags;         // AllowLongestVelocityVector | AllowNeighbourhoodSampling | AllowYCoCg | AllowVarianceClipping | AllowBicubicFilter | AllowDepthThreshold | MarkNoHistoryPixels
//
///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

float3 DebugColourNoHistory()
{
#if 1 == ENABLE_DEBUG
    const bool markColours = 1 == ( CBData.DebugFlags & 0x1 )?true:false;
#else
    const bool markColours = false;
#endif

    if ( markColours )
    {
        return float3( 0.2f, 0.8f, 0.2f );
    }

    else
    {
        return float3( 1.0f, 1.0f, 1.0f );
    }
}

bool AllowDepthThreshold()
{
#if 1 == ENABLE_DEBUG
    const bool useDepthThreshold = 2 == ( CBData.DebugFlags & 0x2 )?true:false;
#elif 1 == USE_DEPTH_THRESHOLD
    const bool useDepthThreshold = true;
#else
    const bool useDepthThreshold = false;
#endif
    return useDepthThreshold;
}

bool AllowBicubicFilter()
{
#if 1 == ENABLE_DEBUG
    const bool useBicubicFilter = 4 == ( CBData.DebugFlags & 0x4 )?true:false;
#elif 1 == USE_BICUBIC_FILTER
    const bool useBicubicFilter = true;
#else
    const bool useBicubicFilter = false;
#endif
    return useBicubicFilter;
}

bool AllowVarianceClipping()
{
#if 1 == ENABLE_DEBUG
    const bool useVarianceClipping = 8 == ( CBData.DebugFlags & 0x8 )?true:false;
#elif USE_VARIANCE_CLIPPING != 0
    const bool useVarianceClipping = true;
#else
    const bool useVarianceClipping = false;
#endif
    return useVarianceClipping;
}

bool AllowYCoCg()
{
#if 1 == ENABLE_DEBUG
    const bool useYCoCgSpace = 16 == ( CBData.DebugFlags & 0x10 )?true:false;
#elif 1 == USE_YCOCG_SPACE
    const bool useYCoCgSpace = true;
#else
    const bool useYCoCgSpace = false;
#endif
    return useYCoCgSpace;
}

bool AllowNeighbourhoodSampling()
{
#if 1 == ENABLE_DEBUG
    const bool useNeighbourhoodSampling = 32 == ( CBData.DebugFlags & 0x20 )?true:false;
#elif 1 == ALLOW_NEIGHBOURHOOD_SAMPLING
    const bool useNeighbourhoodSampling = true;
#else
    const bool useNeighbourhoodSampling = false;
#endif
    return useNeighbourhoodSampling;
}

bool AllowLongestVelocityVector()
{
#if 1 == ENABLE_DEBUG
    const bool useLongestVelocityVector = 64 == ( CBData.DebugFlags & 0x40 )?true:false;
#elif 1 == USE_LONGEST_VELOCITY_VECTOR
    const bool useLongestVelocityVector = true;
#else
    const bool useLongestVelocityVector = false;
#endif
    return useLongestVelocityVector;
}
