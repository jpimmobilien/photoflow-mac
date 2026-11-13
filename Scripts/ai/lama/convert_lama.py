# Based on github.com/mallman/CoreMLaMa (Apache-2.0, see LICENSE.txt).
# PhotoFlow change: the TorchScript Big-LaMa export (the file IOPaint uses) is loaded directly with
# torch.jit.load instead of importing IOPaint, whose dependency chain no longer installs cleanly.
import hashlib, os, urllib.request
import coremltools as ct
import torch

from CoreMLaMa import CoreMLaMa

URL = "https://github.com/Sanster/models/releases/download/add_big_lama/big-lama.pt"
MD5 = "e3aa4aaa15225a33ec84f9f4bc47e500"   # checksum IOPaint pins for this file
if not os.path.exists("big-lama.pt"):
    urllib.request.urlretrieve(URL, "big-lama.pt")
md5 = hashlib.md5(open("big-lama.pt", "rb").read()).hexdigest()
print("big-lama.pt md5", md5)
assert md5 == MD5, "unexpected big-lama.pt checksum"

class _Holder:
    model = torch.jit.load("big-lama.pt", map_location="cpu").eval()

model_manager = _Holder()

# Fixed image/mask size
# Flexible input shapes are not (currently) supported, for various reasons
size = (800, 800) # pixel width x height

# Image/mask shapes in PyTorch format
image_shape=(1, 3, size[1], size[0])
mask_shape=(1, 1, size[1], size[0])

lama_inpaint_model = model_manager.model
model = CoreMLaMa(lama_inpaint_model).eval()

print("Scripting CoreMLaMa")
jit_model = torch.jit.script(model)

print("Converting model")
# Note that ct.ImageType assumes an 8 bpp image, while LaMa
# uses 32-bit FP math internally. Creating a Core ML model
# that can work with 32-bit FP image inputs is on the "To Do"
# list
coreml_model = ct.convert(
    jit_model,
    convert_to="mlprogram",
    compute_precision=ct.precision.FLOAT32,
    compute_units=ct.ComputeUnit.CPU_AND_GPU,
    inputs=[
        ct.ImageType(name="image",
                     shape=image_shape,
                     scale=1/255.0),
        ct.ImageType(
            name="mask",
            shape=mask_shape,
            color_layout=ct.colorlayout.GRAYSCALE)
    ],
    outputs=[ct.ImageType(name="output")],
    skip_model_load=True
)

coreml_model_file_name = "LaMa.mlpackage"
print(f"Saving model to {coreml_model_file_name}")
coreml_model.save(coreml_model_file_name)
print("Done!")
