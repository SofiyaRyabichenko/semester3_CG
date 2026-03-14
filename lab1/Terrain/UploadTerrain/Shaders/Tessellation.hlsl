#include "LightingUtil.hlsl"

Texture2D gDiffuseMap : register(t0);
Texture2D gNormalMap : register(t1);
Texture2D gHeightMap : register(t2);
Texture2D gPaintMap : register(t3);
Texture2D gBrushTex : register(t4);

SamplerState gsamPointClamp : register(s1);
SamplerState gsamLinearClamp : register(s3);

cbuffer cbPerObject : register(b0)
{
    float4x4 gWorld;
    float4x4 gTexTransform;
};

cbuffer cbPass : register(b1)
{
    float4x4 gView;
    float4x4 gInvView;
    float4x4 gProj;
    float4x4 gInvProj;
    float4x4 gViewProj;
    float4x4 gInvViewProj;
    float3 gEyePosW;
    float pad1;
    float2 gRenderTargetSize;
    float2 gInvRenderTargetSize;
    float gNearZ;
    float gFarZ;
    float gTotalTime;
    float gDeltaTime;
    float4 gAmbientLight;
    Light gLights[MaxLights];
};

cbuffer cbTessellation : register(b3)
{
    float gMinTessDistance;
    float gMaxTessDistance;
    float gMinTessFactor;
    float gMaxTessFactor;
    float gHeightScale;
    float gTessSlopeScale;
    float2 _pad_tess;
};

cbuffer cbPerPatch : register(b4)
{
    float2 gPatchOffset; // offset патча в мировых координатах
    float gPatchSize; // размер патча
    int gLODLevel; // уровень LOD
    float2 _pad_patch;
};

struct VertexIn
{
    float3 PosL : POSITION;
};
struct VertexOut
{
    float3 PosL : POSITION;
};

VertexOut VS(VertexIn vin)
{
    VertexOut vout;
    vout.PosL = vin.PosL;
    return vout;
}

struct PatchTess
{
    float EdgeTess[4] : SV_TessFactor;
    float InsideTess[2] : SV_InsideTessFactor;
};

PatchTess CalcAdaptiveTessFactors(float3 centerWorldPos)
{
    PatchTess pt;

    // Только расстояние от камеры — чистая дистанционная тесселяция
    float dist = distance(centerWorldPos, gEyePosW);

    // Классическая формула: близко ? distFactor ? 1.0, далеко ? 0.0
    float distFactor = saturate((gMaxTessDistance - dist) / (gMaxTessDistance - gMinTessDistance));

    // Плавный lerp между минимальным и максимальным фактором
    float finalTess = lerp(gMinTessFactor, gMaxTessFactor, distFactor);

    // Округляем до ближайшего целого (можно и до чётного — ещё меньше моргания)
    finalTess = round(finalTess);

    // Все ребра и внутренние факторы одинаковые
    pt.EdgeTess[0] = pt.EdgeTess[1] = pt.EdgeTess[2] = pt.EdgeTess[3] = finalTess;
    pt.InsideTess[0] = pt.InsideTess[1] = finalTess;

    return pt;
}

PatchTess ConstantHS(InputPatch<VertexOut, 4> patch, uint patchID : SV_PrimitiveID)
{
    PatchTess pt;
    
    // LOD растет ? тесселяция растет
    // LOD 0 ? tess = 4
    // LOD 1 ? tess = 8
    // LOD 2 ? tess = 16
    // LOD 3 ? tess = 32
    // LOD 4+ ? tess = 64
    
    float baseTessFactor = gMinTessFactor * pow(2.0, (float) gLODLevel);
    float tess = clamp(baseTessFactor, gMinTessFactor, gMaxTessFactor);
    
    pt.EdgeTess[0] = pt.EdgeTess[1] = pt.EdgeTess[2] = pt.EdgeTess[3] = tess;
    pt.InsideTess[0] = pt.InsideTess[1] = tess;
    
    return pt;
}

[domain("quad")]
[partitioning("integer")]
[outputtopology("triangle_cw")]
[outputcontrolpoints(4)]
[patchconstantfunc("ConstantHS")]
[maxtessfactor(64.0f)]
VertexOut HS(InputPatch<VertexOut, 4> p, uint i : SV_OutputControlPointID, uint patchId : SV_PrimitiveID)
{
    VertexOut hout;
    hout.PosL = p[i].PosL;
    return hout;
}

struct DomainOut
{
    float4 PosH : SV_POSITION;
    float3 PosW : POSITION;
    float2 TexC : TEXCOORD;
    //float TessLevel : BLENDWEIGHT;
    float LODLevel : BLENDWEIGHT;
};

[domain("quad")]
DomainOut DS(PatchTess patchTess, float2 uv : SV_DomainLocation, const OutputPatch<VertexOut, 4> quad)
{
    DomainOut dout;

    float3 top = lerp(quad[0].PosL, quad[1].PosL, uv.x);
    float3 bottom = lerp(quad[2].PosL, quad[3].PosL, uv.x);
    float3 posL = lerp(top, bottom, uv.y);
    
    float3 posW;
    posW.x = gPatchOffset.x + posL.x * gPatchSize;
    posW.z = gPatchOffset.y + posL.z * gPatchSize;
    
    float2 heightmapUV;
    heightmapUV.x = (posW.x + 100.0f) / 200.0f;
    heightmapUV.y = (posW.z + 100.0f) / 200.0f;
    
    float height = gHeightMap.SampleLevel(gsamPointClamp, heightmapUV, 0).r;
    posW.y = height * gHeightScale;
    
    float2 texC = posW.xz * 0.005f + 0.5f;

    dout.PosW = posW;
    dout.PosH = mul(float4(posW, 1.0f), gViewProj);
    dout.TexC = texC;
    dout.LODLevel = (float) gLODLevel;

    return dout;
}

/////////////////ОБЫЧНЫЙ
// ------------------- Pixel Shader -------------------
//float4 PS(DomainOut pin) : SV_Target
//{
//    float4 diffuse = gDiffuseMap.Sample(gsamLinearClamp, pin.TexC);

//    float3 normalW = normalize(cross(ddx_coarse(pin.PosW), ddy_coarse(pin.PosW)));
//    float3 lightDir = normalize(float3(0.5f, 1.0f, 0.3f));
//    float ndl = saturate(dot(normalW, lightDir)) * 0.7f + 0.3f;

//    return diffuse * ndl;
//}

//////////////РАСКРАСКА ПО ЦВЕТАМ В ЗАВИСИМОСТИ ОТ LOD УРОВНЯ
//float4 PS(DomainOut pin) : SV_Target
//{
//    float4 tex = gDiffuseMap.Sample(gsamLinearClamp, pin.TexC);

//    int lod = (int) pin.LODLevel;

//    float3 debugColor;
    
//    // 5 реальных уровней LOD (0-4) с разной тесселяцией
//    if (lod == 0)
//        debugColor = float3(0.5, 0, 1); // фиолетовый — LOD 0 (tess 4)
//    else if (lod == 1)
//        debugColor = float3(0, 0.5, 1); // синий — LOD 1 (tess 8)
//    else if (lod == 2)
//        debugColor = float3(0, 1, 0.5); // голубой — LOD 2 (tess 16)
//    else if (lod == 3)
//        debugColor = float3(1, 1, 0); // желтый — LOD 3 (tess 32)
//    else // lod == 4
//        debugColor = float3(1, 0, 0); // красный — LOD 4+ (tess 64)

//    return float4(debugColor, 1.0f) * 0.7 + tex * 0.3;
//}

//Раскраска по нажатию колесика
//- Вычисляем UV координаты на основе мировой позиции вершины
//- Сэмплируем paintmap
//- Смешиваем основно йцвет с цветом(lerp по альфа-каналу)
//float4 PS(DomainOut pin) : SV_Target
//{
//    float4 diffuse = gDiffuseMap.Sample(gsamLinearClamp, pin.TexC);

//    float3 normalW = normalize(cross(ddx_coarse(pin.PosW), ddy_coarse(pin.PosW)));
//    float3 lightDir = normalize(float3(0.5f, 1.0f, 0.3f));
//    float ndl = saturate(dot(normalW, lightDir)) * 0.7f + 0.3f;

//    // UV для paint map (должны совпадать с WorldToTerrainUV в C++)
//    float2 terrainUV;
//    terrainUV.x = (pin.PosW.x + 100.0f) / 200.0f;
//    terrainUV.y = (pin.PosW.z + 100.0f) / 200.0f;
    
//    // Сэмплируем paint map
//    float4 paintColor = gPaintMap.Sample(gsamLinearClamp, terrainUV);
    
//    // Базовый цвет
//    float4 finalColor = diffuse * ndl;
    
//    // Смешиваем с paint map
//    finalColor = lerp(finalColor, paintColor, paintColor.a);
    
//    return finalColor;
//}

float4 PS(DomainOut pin) : SV_Target
{
    float4 diffuse = gDiffuseMap.Sample(gsamLinearClamp, pin.TexC);

    float3 normalW = normalize(cross(ddx_coarse(pin.PosW), ddy_coarse(pin.PosW)));
    float3 lightDir = normalize(float3(0.5f, 1.0f, 0.3f));
    float ndl = saturate(dot(normalW, lightDir)) * 0.7f + 0.3f;

    // UV для paint map
    float2 terrainUV;
    terrainUV.x = (pin.PosW.x + 100.0f) / 200.0f;
    terrainUV.y = (pin.PosW.z + 100.0f) / 200.0f;
    
    // Сэмплируем paint map (маска)
    float4 paintMask = gPaintMap.Sample(gsamLinearClamp, terrainUV);
    
    // Сэмплируем brush текстуру
    // Можно использовать те же UV или terrainUV
    float4 brushColor = gBrushTex.Sample(gsamLinearClamp, pin.TexC);
    
    // Базовый цвет
    float4 finalColor = diffuse * ndl;
    
    // Смешиваем с brush текстурой
    finalColor = lerp(finalColor, brushColor * ndl, paintMask.a);
    
    return finalColor;
}