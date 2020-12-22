# Gen-friendly TAA integrated to MSFT's MiniEngine

## Implementation: 
Gen-friendly TAA comes with quality and performance settings allow to tweak the same shader to work efficiently with Gen iGPUs as well as providing best quality on dGPUs. TAA is rendering technique that reuses color samples from previous frames to achieve temporal supersampling. It is a post-process technique that takes as input screen velocity map, previous frames color buffer (accumulation buffer also known as history buffer), previous frame depth buffer and current frame color buffer and its depth buffer. Samples from previous frame are reprojected using the velocity map to current frame pixel’s location and used to achieve (temporal) supersampling. In addition, subpixel jitter is used in the main projection matrix or to the viewpoer (MiniEngine uses the latter) during rendering so that the sampled pixels come from slightly different subpixel locations even when the camera (view) is not moving between frames. Please, refer to TAAResolve.hlsl for more detailed description about switches to adjust quality/perf ratio.

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
