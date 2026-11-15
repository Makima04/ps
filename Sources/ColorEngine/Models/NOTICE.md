# Model sources

FaceParsing uses the Core ML conversion published by mickeyvanolst/face-parsing-coreml.
Pinned revision 289c64b0db3acb100e22a650becb5e300be8b7f4.
Source https://huggingface.co/mickeyvanolst/face-parsing-coreml
Upstream https://github.com/yakhyo/face-parsing
The conversion and upstream repository identify the model as MIT licensed.

ClothSegmentation uses the U2NET Core ML conversion published by jerhoads/cloth-segmentation-coreml.
Pinned revision 9c0a03afb544587402484a977d71383a1d79613d.
Source https://huggingface.co/jerhoads/cloth-segmentation-coreml
Upstream https://github.com/levindabhi/cloth-segmentation
The conversion and upstream repository identify the model as MIT licensed.
The publisher reports training with iMaterialist Fashion 2019.

Downloaded weight hashes are verified by Scripts/prepare-models.py.
Core ML models are compiled on the build machine and bundled for local inference.
