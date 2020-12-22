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

#include "ShaderUtility.hlsli"
#include "TemporalRS.hlsli"

Texture2D<float4> TemporalColor : register(t0);
RWTexture2D<float3> OutColor : register(u0);

cbuffer InlineConstants : register( b0 )
{
    float WA, WB, IsPreMultipliedAlpha;
}

float LuminanceRec709( float3 inRGB )
{
    return dot( inRGB, float3( 0.2126f, 0.7152f, 0.0722f ) );
}

float3 InverseReinhard( float3 inRGB )
{
    return inRGB / ( 1.f - LuminanceRec709( inRGB ) );
}

[RootSignature(Temporal_RootSig)]
[numthreads( 8, 8, 1 )]
void main( uint3 DTid : SV_DispatchThreadID )
{
    float4 Color = TemporalColor[DTid.xy];
    OutColor[ DTid.xy ] = IsPreMultipliedAlpha > 0.f ? Color.rgb / max( Color.w, 1e-6 ) : InverseReinhard( Color.rgb );
}
