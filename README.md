# DISCONTINUATION OF PROJECT #
This project will no longer be maintained by Intel.
Intel has ceased development and contributions including, but not limited to, maintenance, bug fixes, new releases, or updates, to this project.
Intel no longer accepts patches to this project.
# Intel® Graphics Optimized TAA

## Implementation: 
This DirectX® 12 Compute Shader Temporal Anti-Aliasing (TAA) implementation has been optimized so that TAA performs better on Intel® Graphics Gen11 integrated GPUs, as well as Intel® Iris® Xe Graphics integrated and discrete GPUs. Yet the same code can still yield strong TAA quality and performance on other discrete GPUs.  We demonstrate this new optimized TAA, inside of the well known Microsoft MiniEngine codebase.
TAA is rendering technique that reuses colour samples from previous frames to achieve temporal super-sampling. It is a post-processing technique that takes as input screen velocity map, the previous frame’s colour buffer (aka accumulation buffer or history buffer), the previous frame’s depth buffer and current frame color buffer and its depth buffer. Samples from the previous frame are re-projected using the velocity map to the current frame’s pixel location, and then used to achieve temporal super-sampling. In addition, subpixel jitter is used in the main projection matrix or to the viewport (Microsoft MiniEngine uses the latter) during rendering so that the sampled pixels come from different subpixel locations even when the camera (view) is not moving between frames. Please, refer to TAAResolve.hlsl and TemporalEffects.cpp for more detailed description about implementation.

With quality settings the TAA takes as little as:
- 1.9ms on Intel® Iris® Xe Graphics (i7-1186G7) or
- 3.6ms on Intel® Iris® Plus Graphics (i7-1065G7)
to anti-alias a 1080p 32bpp frame buffer.

With performance settings the TAA takes only 0.9ms, 1.7ms respectively.

To achieve such performance a certain optimizations have been made:
- fp16 optimization. That is, the shader is optimized for 16-bit floating point calculations except two where lack of precision was too visible. To toggle fp16 support set #define USE_FP16 to 1 and enable SM6.2 16-bit precision in the shader compiler by adding "-enable-16bit-types" option. Enabling fp16 improves peformance by x1.04,
- toggable thread global shared memory (#define USE_TGSM) that is a win in 64bpp (x1.05) but performs slightly worse in 32bpp with VarianceClipping rotating grid that changes every other frame either x or + pattern,
- VarianceClipping instead of using the rotating grid may use 3x3 sampling pattern and a ray-AABB intersection to ensure maximum quality. By default a clipping to AABB boundaries is used. VarianceClipping should not be switched off as it is the main anti-ghosting solution. To control it go to #define USE_VARIANCE_CLIPPING,
- colour space used for the variance clipping can be either RGB or YCoCg. The latter gives the best quality where the former may in certain scenarios cause the image to be slightly more reddish (the performance speed up is x1.03). Refer to #define USE_YCOCG_SPACE,
- toggable using the longest velocity vector in the closest neighbourhood. That greatly improves the anti-aliasing quality of edges - #define USE_LONGEST_VELOCITY_VECTOR in the shader code,
- history buffer can by sampled by either using a Bicubic sampling or Bilinear sampling, the former gives very good quality (no sharpening is needed) but using the latter gives x1.2 performance speedup,
and many more. 

## Switches to control quality/performance ratio:
* #USE_DEPTH_THRESHOLD - checks the depth buffers (current and previous frame) and if the depth difference is larger than the expected value (which is stored with Motion Vectors), the pixel is marked as no-history. This option helps removing ghosting artifacts.
* #USE_VARIANCE_CLIPPING - the main algorithm for removing ghosting artifacts. It calculates mean/standard deviation to build an AABB of expected colour values in the given pixel neighbourhood and then clamp (cheaper) or intersect (better quality) the history colour against it to remove ghosting/too bright pixels. AABB min/max is calculated: mean -/+ Gamma * standard_deviation. Larger Gamma improves temporally stable results but may increase ghosting hence a confidence factor is used to lerp between stability and anti-ghosting. The confidence factor is build from the velocity of the current pixel and its depth difference between frames. The variance clipping should always be enabled in either option because this is the main solution for ghosting artifacts. Gamma is controllable using two values: MIN_VARIANCE_GAMMA and MAX_VARIANCE_GAMMA. The former is used during movement and the latter on still image. The ration between them is calculated using the motion vector.
* #USE_YCOCG_SPACE - The YCoCg colour space is used for Variance Clipping. It improves precision of the AABB intersection. Using RGB space image may get more reddish in certain scenarios.
* #ALLOW_NEIGHBOURHOOD_SAMPLING - If there’s no history a neighbourhood in the cross pattern is sampled.
* #USE_BICUBIC_FILTER - Bicubic (5-tap) filter is preferred sampling option for the history buffer (temporal accumulation of previous samples). If disabled, Bilinear filtering is used. Bilinear introduces more blur to the final image but is faster.
* #USE_LONGEST_VELOCITY_VECTOR - When reading Velocity vector (Motion vector's Z component) for the given pixel, its neighbourhood is sampled and then the longest vector is chosen. This greatly improves edges quality under motion. Unfortunately it costs, hence 9 samples or 5 samples options are provided. Disabling the option and leaving Bicubic filterin on enables a mixed solution: Bilinear on edges and Bicubic anywhere else. This is for testing mostly.  Bilinear introduces more blur that softens edges. Edge detection is done by Depth Gathering and checking whether min/max is larger than a threshold.
* #FRAME_VELOCITY_IN_PIXELS_DIFF should be tweaked based on resolution. Empirically 128 has been set for 1080p. If the motion vector lenght is larger than this number, the pixel is marked as no-history.
* #VARIANCE_BBOX_NUMBER_OF_SAMPLES - whether to use 9 samples or 5 samples to build the AABB for Variance Clipping.
* #VARIANCE_INTERSECTION_MAX_T - max "distance" between source colour and target colour for USE_VARIANCE_CLIPPING set to the intersection mode. Setting this to a larger value allows more bright pixels from the history buffer to be leaved unchanged.
* #KEEP_HISTORY_TONE_MAPPED - whether to keep all colour calculation on tone-mapped colours. This is default option. The output buffer which becomes the history buffer in a next frame is tone-mapped. Next post-process should take this into account.
* #USE_TONE_MAPPED_COLOUR_ONLY_IN_FINAL - currently this is set as !KEEP_HISTORY_TONE_MAPPED however it may be controlled manually if needed.
* #USE_TGSM - allows using thread group shared memory to store current frame colour
* #USE_FP16 - allows to use 16 bit precision for floating point calculations. This requires SM6.2 and using "-enable-16bit-types" as a compiler option.
* #ENABLE_DEBUG - whether to pass parameters from the UI to the shader.

## Getting started:
* Open ModelViewer/ModelViewer_VS16.sln
* Select configuration: Debug (full validation), Profile (instrumented), Release
* Select platform
* Build and run
* TAA implementation is at TAAResolve.hlsl

## Controls:
* forward/backward/strafe: left thumbstick or WASD (FPS controls)
* up/down: triggers or E/Q
* yaw/pitch: right thumbstick or mouse
* toggle slow movement: click left thumbstick or lshift
* open debug menu: back button or backspace
* navigate debug menu: dpad or arrow keys
* toggle debug menu item: A button or return
* adjust debug menu value: dpad left/right or left/right arrow keys
