Shader "Hidden/VXGI"
{
  Properties
  {
    _MainTex("Albedo", 2D) = "white" {}
  }

  SubShader
  {
    Blend One OneMinusSrcAlpha

    Pass
    {
      Name "ConeTracing"

      CGPROGRAM
      #pragma target 4.5
      #pragma vertex vert
      #pragma fragment frag
      #pragma multi_compile __ TRACE_SUN

      #include "UnityCG.cginc"
      #include "Packages/com.looooong.srp.vxgi/ShaderLibrary/Radiances/Pixel.cginc"

      struct v2f
      {
        float4 vertex : SV_POSITION;
        float2 uv : TEXCOORD;
      };

      struct FragmentOutput {
        float4 color : SV_TARGET;
        float depth : SV_DEPTH;
      };

      float3 CameraPosition;
      float4 _MainTex_TexelSize;
      float4 Irradiance_TexelSize;
      Texture2D _MainTex;
      Texture2D Depth;
      Texture2D Specular;
      Texture2D Normal;
      Texture2D Emission;
      Texture2D Irradiance;
      Texture2D IrradianceDepth;
      float4x4 ClipToWorld;

      v2f vert (appdata_base v)
      {
        v2f o;
        o.vertex = UnityObjectToClipPos(v.vertex);
        o.uv = v.texcoord;
        return o;
      }

      static int2 GatherOffsets[4] = {
        int2(0, 1),
        int2(1, 1),
        int2(1, 0),
        int2(0, 0)
      };

      float3 NearestDepthIrradiance(float2 uv, float depth)
      {
        depth = LinearEyeDepth(depth);
        float4 neighbors = IrradianceDepth.Gather(linear_clamp_sampler, uv);
        float4 distances;

        float minDist = 1.e8f;
        float minIndex = -1;

        [unroll]
        for (int i = 0; i < 4; i++) {
          distances[i] = distance(depth, LinearEyeDepth(neighbors[i]));

          if (distances[i] < minDist) {
            minDist = distances[i];
            minIndex = i;
          }
        }

        if (all(distances < 0.1)) {
          return Irradiance.Sample(linear_clamp_sampler, uv);
        } else {
          return Irradiance.Load(int3(mad(uv, Irradiance_TexelSize.zw, -0.5) + GatherOffsets[minIndex], 0));
        }
      }

      FragmentOutput frag (v2f i)
      {
        FragmentOutput o;
        o.color = 0.0;
        o.depth = Depth.Sample(point_clamp_sampler, i.uv).r;

        if (o.depth > 0.0) {
          #if UNITY_REVERSED_Z
            float clipZ = o.depth;
          #else
            float clipZ = mad(2.0, o.depth, -1.0);
          #endif

          LightingData data;

          float4 worldPosition = mul(ClipToWorld, float4(mad(2.0, i.uv, -1.0), clipZ, 1.0));
          data.worldPosition = worldPosition.xyz / worldPosition.w;

          float2 specular = Specular.Sample(point_clamp_sampler, i.uv);
          data.baseColor = _MainTex.Sample(point_clamp_sampler, i.uv);
          data.glossiness = specular.r;
          data.metallic = specular.g;

          data.vecN = mad(Normal.Sample(point_clamp_sampler, i.uv), 2.0, -1.0);
          data.vecV = normalize(CameraPosition - data.worldPosition);

          data.Initialize();

          float3 emission = Emission.Sample(point_clamp_sampler, i.uv);
          float3 indirectDiffuseRadiance = NearestDepthIrradiance(i.uv, o.depth);

          o.color = float4(emission + PixelRadiance(data, indirectDiffuseRadiance), 1.0);
        }

        return o;
      }
      ENDCG
    }

    Pass
    {
      Name "DiffuseConeTracing"

      CGPROGRAM
      #pragma vertex vert
      #pragma fragment frag
      #pragma multi_compile __ TRACE_SUN

      #include "UnityCG.cginc"
      #include "Packages/com.looooong.srp.vxgi/ShaderLibrary/Radiances/Pixel.cginc"

      struct v2f
      {
        float4 vertex : SV_POSITION;
        float2 uv : TEXCOORD;
      };

      Texture2D Depth;
      Texture2D Normal;
      float4x4 ClipToVoxel;

      v2f vert (appdata_base v)
      {
        v2f o;
        o.vertex = UnityObjectToClipPos(v.vertex);
        o.uv = v.texcoord;
        return o;
      }

      float4 frag (v2f i) : SV_TARGET
      {
        float4 color = 0.0;
        float depth = Depth.Sample(point_clamp_sampler, i.uv).r;

        if (depth > 0.0) {
          #if UNITY_REVERSED_Z
            float clipZ = depth;
          #else
            float clipZ = mad(2.0, depth, -1.0);
          #endif

          float4 voxel = mul(ClipToVoxel, float4(mad(2.0, i.uv, -1.0), clipZ, 1.0));
          float3 position = voxel.xyz / voxel.w;

          float3 normal = mad(Normal.Sample(point_clamp_sampler, i.uv), 2.0, -1.0);

          color = float4(IndirectDiffusePixelRadiance(position, normal), 1.0);
        }

        return color;
      }
      ENDCG
    }

    Pass
    {
      Name "Mipmap"

      CGPROGRAM
      #pragma target 4.5
      #pragma vertex vert
      #pragma fragment frag
      #pragma multi_compile __ RADIANCE_POINT_SAMPLER

      #include "UnityCG.cginc"
      #include "Packages/com.looooong.srp.vxgi/ShaderLibrary/Utilities.cginc"
      #include "Packages/com.looooong.srp.vxgi/ShaderLibrary/Radiances/Sampler.cginc"

      struct v2f
      {
        float4 position : SV_POSITION;
        float3 view : POSITION1;
      };

      // 6 inner faces of a cube
      static float3 Vertices[24] = {
        float3(0.0, 0.0, 0.0),
        float3(1.0, 0.0, 0.0),
        float3(1.0, 1.0, 0.0),
        float3(0.0, 1.0, 0.0),

        float3(0.0, 0.0, 0.0),
        float3(0.0, 1.0, 0.0),
        float3(0.0, 1.0, 1.0),
        float3(0.0, 0.0, 1.0),

        float3(0.0, 0.0, 0.0),
        float3(0.0, 0.0, 1.0),
        float3(1.0, 0.0, 1.0),
        float3(1.0, 0.0, 0.0),

        float3(1.0, 1.0, 1.0),
        float3(1.0, 0.0, 1.0),
        float3(0.0, 0.0, 1.0),
        float3(0.0, 1.0, 1.0),

        float3(1.0, 1.0, 1.0),
        float3(1.0, 1.0, 0.0),
        float3(1.0, 0.0, 0.0),
        float3(1.0, 0.0, 1.0),

        float3(1.0, 1.0, 1.0),
        float3(0.0, 1.0, 1.0),
        float3(0.0, 1.0, 0.0),
        float3(1.0, 1.0, 0.0),
      };

      static float DitherPattern[4][4] = {
        0.0000, 0.5000, 0.1250, 0.6250,
        0.7500, 0.2200, 0.8750, 0.3750,
        0.1875, 0.6875, 0.0625, 0.5625,
        0.9375, 0.4375, 0.8125, 0.3125
      };

      float Level;
      float Step;

      v2f vert(uint id : SV_VertexID)
      {
        float3 v = Vertices[id];

        v2f o;
        o.position = UnityObjectToClipPos(v);
        o.view = UnityObjectToViewPos(v);
        return o;
      }

      half4 frag(v2f i) : SV_TARGET
      {
        float3 view = i.view;
        float3 unit = view * Step / view.z;
        view += unit * DitherPattern[i.position.x % 4][i.position.y % 4];
        float3 coordinate = mul(transpose(UNITY_MATRIX_IT_MV), float4(view, 1.0));

        half4 color = half4(0.0, 0.0, 0.0, 0.0);

        while ((view.z <= 2 * Step) && (TextureSDF(coordinate) > -0.000001)) {
          half4 sample = SampleRadiance(coordinate, Level);
          color = sample + color * (1 - sample.a);
          view += unit;
          coordinate = mul(transpose(UNITY_MATRIX_IT_MV), float4(view, 1.0));
        }

        return color;
      }

      ENDCG
    }

    Pass
    {
      Name "DepthCopy"

      ZWrite On

      CGPROGRAM
      #pragma vertex vert
      #pragma fragment frag

      #include "UnityCG.cginc"

      struct v2f
      {
        float4 vertex : SV_POSITION;
        float2 uv : TEXCOORD;
      };

      Texture2D<float> _MainTex;
      SamplerState point_clamp_sampler;

      v2f vert (appdata_base v)
      {
        v2f o;
        o.vertex = UnityObjectToClipPos(v.vertex);
        o.uv = v.texcoord;
        return o;
      }

      float4 frag (v2f i, out float depth : SV_DEPTH) : SV_TARGET
      {
        depth = _MainTex.Sample(point_clamp_sampler, i.uv);
        return 0.0;
      }
      ENDCG
    }
  }
}
