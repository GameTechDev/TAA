//
// Copyright (c) Microsoft. All rights reserved.
// This code is licensed under the MIT License (MIT).
// THIS CODE IS PROVIDED *AS IS* WITHOUT WARRANTY OF
// ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING ANY
// IMPLIED WARRANTIES OF FITNESS FOR A PARTICULAR
// PURPOSE, MERCHANTABILITY, OR NON-INFRINGEMENT.
//
// Developed by Minigraph
//
// Author:  James Stanard 
//

#include "pch.h"
#include "TemporalEffects.h"
#include "BufferManager.h"
#include "GraphicsCore.h"
#include "CommandContext.h"
#include "SystemTime.h"
#include "PostEffects.h"

#include "CompiledShaders/TemporalBlendCS.h"
#include "CompiledShaders/BoundNeighborhoodCS.h"
#include "CompiledShaders/ResolveTAACS.h"
#include "CompiledShaders/SharpenTAACS.h"
#include "CompiledShaders/TAAResolve.h"

using namespace Graphics;
using namespace Math;
using namespace TemporalEffects;

namespace TemporalEffects
{
    uint32_t TAAEnabledStatus = 2;  // 0 - disabled, 1 - MSFT's, 2 - Intel's

    BoolVar EnableMSFTTAA( "Graphics/AA/TAA/MSFT/Enable", 1 == TAAEnabledStatus ? true : false );
    BoolVar ITAA_Enable( "Graphics/AA/TAA/Intel/Enable", 2 == TAAEnabledStatus ? true : false );
    BoolVar ITAA_AllowLongestVelocityVector( "Graphics/AA/TAA/Intel/Allow Longest Velocity Vector", true );
    BoolVar ITAA_AllowDepthThreshold( "Graphics/AA/TAA/Intel/Allow Depth Threshold", true );
    BoolVar ITAA_AllowVarianceClipping( "Graphics/AA/TAA/Intel/Allow Variance Clipping", true );
    BoolVar ITAA_AllowYCoCg( "Graphics/AA/TAA/Intel/Allow YCoCg", true );
    BoolVar ITAA_AllowBicubicFilter( "Graphics/AA/TAA/Intel/Allow Bicubic Filter", true );
    BoolVar ITAA_AllowNeighbourhoodSampling( "Graphics/AA/TAA/Intel/Allow Neighbourhood Sampling", true );
    BoolVar ITAA_MarkNoHistoryPixels( "Graphics/AA/TAA/Intel/Mark No-History Pixels", false );
    BoolVar ITAA_PreferBluenoise( "Graphics/AA/TAA/Intel/Prefer Bluenoise", false );
    NumVar TemporalMaxLerp("Graphics/AA/TAA/MSFT/Blend Factor", 1.0f, 0.0f, 1.0f, 0.01f);
    ExpVar TemporalSpeedLimit("Graphics/AA/TAA/MSFT/Speed Limit", 64.0f, 1.0f, 1024.0f, 1.0f);
    NumVar Sharpness("Graphics/AA/TAA/Sharpness", 0.5f, 0.0f, 1.0f, 0.25f);
    BoolVar TriggerReset("Graphics/AA/TAA/Reset", false);

    RootSignature s_RootSignature;

    ComputePSO s_TemporalBlendCS;
    ComputePSO s_BoundNeighborhoodCS;
    ComputePSO s_SharpenTAACS;
    ComputePSO s_ResolveTAACS;
    ComputePSO s_IntelTAAResolve;

    uint32_t s_FrameIndex = 0;
    uint32_t s_FrameIndexMod2 = 0;
    float s_JitterX = 0.5f;
    float s_JitterY = 0.5f;
    float s_JitterDeltaX = 0.0f;
    float s_JitterDeltaY = 0.0f;

    void ApplyTemporalAA(ComputeContext& Context);
    void ApplyTemporalIntelAA( ComputeContext& Context, const Matrix4& CurrentProjectionMatrix, const Matrix4& PrevProjectionMatrix );
    void SharpenImage(ComputeContext& Context, ColorBuffer& TemporalColor);
}

void TemporalEffects::Initialize( void )
{
    s_RootSignature.Reset(4, 2);
    s_RootSignature[0].InitAsConstants(0, 4);
    s_RootSignature[1].InitAsDescriptorRange(D3D12_DESCRIPTOR_RANGE_TYPE_SRV, 0, 10);
    s_RootSignature[2].InitAsDescriptorRange(D3D12_DESCRIPTOR_RANGE_TYPE_UAV, 0, 10);
    s_RootSignature[3].InitAsConstantBuffer(1);
    s_RootSignature.InitStaticSampler(0, SamplerLinearBorderDesc);
    s_RootSignature.InitStaticSampler(1, SamplerPointBorderDesc);
    s_RootSignature.Finalize(L"Temporal RS");

#define CreatePSO( ObjName, ShaderByteCode ) \
    ObjName.SetRootSignature(s_RootSignature); \
    ObjName.SetComputeShader(ShaderByteCode, sizeof(ShaderByteCode) ); \
    ObjName.Finalize();

    CreatePSO( s_TemporalBlendCS, g_pTemporalBlendCS );
    CreatePSO( s_BoundNeighborhoodCS, g_pBoundNeighborhoodCS );
    CreatePSO( s_SharpenTAACS, g_pSharpenTAACS );
    CreatePSO( s_ResolveTAACS, g_pResolveTAACS );
    CreatePSO( s_IntelTAAResolve, g_pTAAResolve );

#undef CreatePSO
}

void TemporalEffects::Shutdown( void )
{
}

void TemporalEffects::Update( uint64_t FrameIndex )
{
    const bool hasTAAStatusChanged = ( ( 2 == TAAEnabledStatus ) && ( ( true != ITAA_Enable ) || ( false != EnableMSFTTAA ) ) ) ||
                                     ( ( 1 == TAAEnabledStatus ) && ( ( false != ITAA_Enable ) || ( true != EnableMSFTTAA ) ) ) ||
                                     ( ( 0 == TAAEnabledStatus ) && ( ( false != ITAA_Enable ) || ( false != EnableMSFTTAA ) ) );
    if ( true == hasTAAStatusChanged )
    {
        if ( 2 == TAAEnabledStatus )
        {
            if ( true == EnableMSFTTAA )
            {
                TAAEnabledStatus = 1;
                ITAA_Enable = false;
            }

            else
            {
                assert( false == ITAA_Enable );
                TAAEnabledStatus = 0;
            }
        }

        else if ( 1 == TAAEnabledStatus )
        {
            if ( true == ITAA_Enable )
            {
                TAAEnabledStatus = 2;
                EnableMSFTTAA = false;
            }

            else
            {
                assert( false == EnableMSFTTAA );
                TAAEnabledStatus = 0;
            }
        }

        else
        {
            assert( 0 == TAAEnabledStatus );
            TAAEnabledStatus = ( true == ITAA_Enable ) ? 2 : 1;
        }
    }

    s_FrameIndex = (uint32_t)FrameIndex;
    s_FrameIndexMod2 = s_FrameIndex % 2;

    if (EnableMSFTTAA||ITAA_Enable)// && !DepthOfField::Enable)
    {
        const float* Offset = nullptr;
        float Scale = 1.f;

        if ( EnableMSFTTAA )
        {
            static const float Halton23[ 8 ][ 2 ] =
            {
                { 0.0f / 8.0f, 0.0f / 9.0f }, { 4.0f / 8.0f, 3.0f / 9.0f },
                { 2.0f / 8.0f, 6.0f / 9.0f }, { 6.0f / 8.0f, 1.0f / 9.0f },
                { 1.0f / 8.0f, 4.0f / 9.0f }, { 5.0f / 8.0f, 7.0f / 9.0f },
                { 3.0f / 8.0f, 2.0f / 9.0f }, { 7.0f / 8.0f, 5.0f / 9.0f }
            };

            Offset = Halton23[s_FrameIndex % 8];
        }

        else
        {
            // following work of Vaidyanathan et all: https://software.intel.com/content/www/us/en/develop/articles/coarse-pixel-shading-with-temporal-supersampling.html
            static const float Halton23_16[ 16 ][ 2 ] = { { 0.0f, 0.0f }, { 0.5f, 0.333333f }, { 0.25f, 0.666667f }, { 0.75f, 0.111111f }, { 0.125f, 0.444444f }, { 0.625f, 0.777778f }, { 0.375f ,0.222222f }, { 0.875f ,0.555556f }, { 0.0625f, 0.888889f }, { 0.562500,0.037037 }, { 0.3125f, 0.37037f }, { 0.8125f, 0.703704f }, { 0.1875f,0.148148f }, { 0.6875f, 0.481481f }, { 0.4375f ,0.814815f }, { 0.9375f ,0.259259f } };

            static const float BlueNoise_16[ 16 ][ 2 ] = { { 1.5f, 0.59375f }, { 1.21875f, 1.375f }, { 1.6875f, 1.90625f }, { 0.375f, 0.84375f }, { 1.125f, 1.875f }, { 0.71875f, 1.65625f }, { 1.9375f ,0.71875f }, { 0.65625f ,0.125f }, { 0.90625f, 0.9375f }, { 1.65625f, 1.4375f }, { 0.5f, 1.28125f }, { 0.21875f, 0.0625f }, { 1.843750,0.312500 }, { 1.09375f, 0.5625f }, { 0.0625f, 1.21875f }, { 0.28125f, 1.65625f },
            };

            const bool supportVRS = Graphics::g_bVRS1Supported;
            if ( ( true == ITAA_PreferBluenoise ) && ( true == supportVRS ) )
            {
                Scale = ( true == supportVRS ) && ( true == Graphics::g_bVRS1AdditionalRatesSupported ) ? 2.f : 1.f;
                Offset = BlueNoise_16[ s_FrameIndex % 16 ];
            }

            else
            {
                Scale = ( true == supportVRS ) ? ( true == Graphics::g_bVRS1AdditionalRatesSupported ? 4.f : 2.f ) : 1.f;
                Offset = Halton23_16[ s_FrameIndex % 16 ];
            }
        }

        s_JitterDeltaX = s_JitterX - Offset[ 0 ] * Scale;
        s_JitterDeltaY = s_JitterY - Offset[ 1 ] * Scale;
        s_JitterX = Offset[0] * Scale;
        s_JitterY = Offset[1] * Scale;
    }

    else
    {
        s_JitterDeltaX = s_JitterX - 0.5f;
        s_JitterDeltaY = s_JitterY - 0.5f;
        s_JitterX = 0.5f;
        s_JitterY = 0.5f;
    }

}

uint32_t TemporalEffects::GetFrameIndexMod2( void )
{
    return s_FrameIndexMod2;
}

void TemporalEffects::GetJitterOffset( float& JitterX, float& JitterY )
{
    JitterX = s_JitterX;
    JitterY = s_JitterY;
}

void TemporalEffects::ClearHistory( CommandContext& Context )
{
    GraphicsContext& gfxContext = Context.GetGraphicsContext();

    if (EnableMSFTTAA||ITAA_Enable)
    {
        gfxContext.TransitionResource(g_TemporalColor[0], D3D12_RESOURCE_STATE_RENDER_TARGET);
        gfxContext.TransitionResource(g_TemporalColor[1], D3D12_RESOURCE_STATE_RENDER_TARGET, true);
        gfxContext.ClearColor(g_TemporalColor[0]);
        gfxContext.ClearColor(g_TemporalColor[1]);
    }
}

void TemporalEffects::ResolveImage( CommandContext& BaseContext, const Matrix4& CurrentProjectionMatrix, const Matrix4& PrevProjectionMatrix )
{
    ScopedTimer _prof(L"Temporal Resolve", BaseContext);

    ComputeContext& Context = BaseContext.GetComputeContext();

    static bool s_EnableTAA = false;
    static bool s_EnableIntelTAA = false;

    if (EnableMSFTTAA != s_EnableTAA || TriggerReset || ITAA_Enable != s_EnableIntelTAA )
    {
        ClearHistory(Context);
        s_EnableTAA = EnableMSFTTAA;
        s_EnableIntelTAA = ITAA_Enable;
        TriggerReset = false;
    }
       
    if (EnableMSFTTAA||ITAA_Enable)
    {
        uint32_t Src = s_FrameIndexMod2;
        uint32_t Dst = Src ^ 1;

        if ( ITAA_Enable )
        {
            ApplyTemporalIntelAA( Context, CurrentProjectionMatrix, PrevProjectionMatrix );
        }

        else
        {
            ApplyTemporalAA(Context);
        }

        SharpenImage(Context, g_TemporalColor[Dst]);
    }
}

void TemporalEffects::ApplyTemporalAA(ComputeContext& Context)
{
    ScopedTimer _prof(L"Resolve Image", Context);

    uint32_t Src = s_FrameIndexMod2;
    uint32_t Dst = Src ^ 1;

    Context.SetRootSignature(s_RootSignature);
    Context.SetPipelineState(s_TemporalBlendCS);

    __declspec(align(16)) struct ConstantBuffer
    {
        float RcpBufferDim[2];
        float TemporalBlendFactor;
        float RcpSeedLimiter;
        float CombinedJitter[2];
    };
    ConstantBuffer cbv = {
        1.0f / g_SceneColorBuffer.GetWidth(), 1.0f / g_SceneColorBuffer.GetHeight(),
        (float)TemporalMaxLerp, 1.0f / TemporalSpeedLimit,
        s_JitterDeltaX, s_JitterDeltaY
    };

    Context.SetDynamicConstantBufferView(3, sizeof(cbv), &cbv);

    Context.TransitionResource(g_VelocityBuffer, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    Context.TransitionResource(g_SceneColorBuffer, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    Context.TransitionResource(g_TemporalColor[Src], D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    Context.TransitionResource(g_TemporalColor[Dst], D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    Context.TransitionResource(g_LinearDepth[Src], D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    Context.TransitionResource(g_LinearDepth[Dst], D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    Context.SetDynamicDescriptor(1, 0, g_VelocityBuffer.GetSRV());
    Context.SetDynamicDescriptor(1, 1, g_SceneColorBuffer.GetSRV());
    Context.SetDynamicDescriptor(1, 2, g_TemporalColor[Src].GetSRV());
    Context.SetDynamicDescriptor(1, 3, g_LinearDepth[Src].GetSRV());
    Context.SetDynamicDescriptor(1, 4, g_LinearDepth[Dst].GetSRV());
    Context.SetDynamicDescriptor(2, 0, g_TemporalColor[Dst].GetUAV());

    Context.Dispatch2D(g_SceneColorBuffer.GetWidth(), g_SceneColorBuffer.GetHeight(), 16, 8);
}

void TemporalEffects::ApplyTemporalIntelAA( ComputeContext& Context, const Matrix4& /*CurrentProjectionMatrix*/, const Matrix4& /*PrevProjectionMatrix*/ )
{
    ScopedTimer _prof( L"Resolve (I) Image", Context );

    uint32_t Src = s_FrameIndexMod2;
    uint32_t Dst = Src ^ 1;

    Context.SetRootSignature( s_RootSignature );
    Context.SetPipelineState( s_IntelTAAResolve );

    __declspec( align( 16 ) ) struct FTAAResolve
    {
        Math::Vector4   Resolution;//width, height, 1/width, 1/height
        float           JitterX;
        float           JitterY;
        uint32_t        FrameNumber;
        uint32_t        DebugFlags;
    };

    const float width = static_cast<float>( g_SceneColorBuffer.GetWidth() );
    const float height = static_cast<float>( g_SceneColorBuffer.GetHeight() );
    const float rcpWidth = 1.f / width;
    const float rcpHeight = 1.f / height;

    FTAAResolve cbv;
    cbv.Resolution = Math::Vector4( width, height, rcpWidth, rcpHeight );
    cbv.JitterX = s_JitterDeltaX;
    cbv.JitterY = s_JitterDeltaY;
    cbv.FrameNumber = s_FrameIndexMod2;

    const uint32_t allowLongestVelocityVector = ITAA_AllowLongestVelocityVector;
    const uint32_t allowNeighbourhoodSampling = ITAA_AllowNeighbourhoodSampling;
    const uint32_t allowYCoCg = ITAA_AllowYCoCg;
    const uint32_t allowVarianceClipping = ITAA_AllowVarianceClipping;
    const uint32_t allowBicubicFilter = ITAA_AllowBicubicFilter;
    const uint32_t allowDepthThreshold = ITAA_AllowDepthThreshold;
    const uint32_t markNoHistoryPixels = ITAA_MarkNoHistoryPixels;
    cbv.DebugFlags = allowLongestVelocityVector << 6 | allowNeighbourhoodSampling << 5 | allowYCoCg << 4 | allowVarianceClipping << 3 | allowBicubicFilter << 2 | allowDepthThreshold << 1 | markNoHistoryPixels;

    Context.SetDynamicConstantBufferView( 3, sizeof( cbv ), &cbv );

    Context.TransitionResource( g_VelocityBuffer, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE );
    Context.TransitionResource( g_SceneColorBuffer, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE );
    Context.TransitionResource( g_TemporalColor[ Src ], D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE );
    Context.TransitionResource( g_TemporalColor[ Dst ], D3D12_RESOURCE_STATE_UNORDERED_ACCESS );
    Context.TransitionResource( g_LinearDepth[ Src ], D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE );
    Context.TransitionResource( g_LinearDepth[ Dst ], D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE );
    Context.SetDynamicDescriptor( 1, 0, g_VelocityBuffer.GetSRV() );
    Context.SetDynamicDescriptor( 1, 1, g_SceneColorBuffer.GetSRV() );
    Context.SetDynamicDescriptor( 1, 2, g_TemporalColor[ Src ].GetSRV() );
    Context.SetDynamicDescriptor( 1, 3, g_LinearDepth[ Src ].GetSRV() );
    Context.SetDynamicDescriptor( 1, 4, g_LinearDepth[ Dst ].GetSRV() );
    Context.SetDynamicDescriptor( 2, 0, g_TemporalColor[ Dst ].GetUAV() );

    Context.Dispatch2D( g_SceneColorBuffer.GetWidth(), g_SceneColorBuffer.GetHeight(), 8, 8 );
}

void TemporalEffects::SharpenImage(ComputeContext& Context, ColorBuffer& TemporalColor)
{
    ScopedTimer _prof(L"Sharpen or Copy Image", Context);

    Context.TransitionResource(g_SceneColorBuffer, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    Context.TransitionResource(TemporalColor, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);

    Context.SetPipelineState(Sharpness >= 0.001f ? s_SharpenTAACS : s_ResolveTAACS);
    Context.SetConstants(0, 1.0f + Sharpness, 0.25f * Sharpness, ITAA_Enable ? 0.f : 1.f);
    Context.SetDynamicDescriptor(1, 0, TemporalColor.GetSRV());
    Context.SetDynamicDescriptor(2, 0, g_SceneColorBuffer.GetUAV());
    Context.Dispatch2D(g_SceneColorBuffer.GetWidth(), g_SceneColorBuffer.GetHeight());
}
