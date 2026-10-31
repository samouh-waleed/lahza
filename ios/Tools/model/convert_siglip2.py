#!/usr/bin/env python3
"""Converts SigLIP 2 B/16-256 (google/siglip2-base-patch16-256, Apache-2.0) into the two Core ML models Lahza
loads: an image tower and a text tower, each returning a 768-d L2-normalised embedding.

`make model` runs this in a throwaway virtualenv (Tools/model/requirements.txt). It writes into --out:
  SigLIP2Image.mlmodelc   image tower: RGB 256x256 in, scaled to [-1, 1] by Core ML, 8-bit weights
  SigLIP2Text.mlmodelc    text tower: 64 int32 token ids in (the Gemma tokenizer, lowercased, <eos>, right-padded)
  model.json              what the app needs to use them (id, sizes, tokens, logit scale and bias, source)
  parity.json + parity-*.png  PyTorch fp32 reference embeddings the Swift tests compare against
and fails unless Core ML matches PyTorch (cosine >= --min-cosine) and a red/blue zero-shot check passes.
Models are never committed: they are git-ignored and will be delivered through Background Assets.
"""

import argparse
import json
import pathlib
import shutil
import subprocess
import sys

import coremltools as ct
import numpy as np
import torch
from coremltools.optimize.coreml import OpLinearQuantizerConfig, OptimizationConfig, linear_quantize_weights
from huggingface_hub import snapshot_download
from PIL import Image, ImageDraw
from transformers import AutoProcessor, SiglipModel

REPO = "google/siglip2-base-patch16-256"
MODEL_ID = "siglip2-b16-256"
IMAGE_SIZE = 256
TEXT_LENGTH = 64
PROMPTS = ["a red square", "a blue square", "a photo of a soccer match", "sunset at the beach"]


class ImageTower(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, pixel_values):
        embedding = self.model.get_image_features(pixel_values=pixel_values)
        return embedding / embedding.norm(dim=-1, keepdim=True)


class TextTower(torch.nn.Module):
    """Token ids only: the attention mask the processor would pass is derived from the padding."""

    def __init__(self, model, pad_id, uses_mask):
        super().__init__()
        self.model = model
        self.pad_id = pad_id
        self.uses_mask = uses_mask

    def forward(self, input_ids):
        mask = (input_ids != self.pad_id).to(torch.int64) if self.uses_mask else None
        embedding = self.model.get_text_features(input_ids=input_ids, attention_mask=mask)
        return embedding / embedding.norm(dim=-1, keepdim=True)


def test_images(out):
    """Deterministic 256x256 PNGs (no resize needed, so both pipelines see the same pixels)."""
    images = {}
    for name, colour in [("red", (220, 30, 30)), ("blue", (30, 60, 220))]:
        image = Image.new("RGB", (IMAGE_SIZE, IMAGE_SIZE), (245, 245, 245))
        ImageDraw.Draw(image).rectangle([48, 48, 208, 208], fill=colour)
        images[name] = image
    x = np.linspace(0, 255, IMAGE_SIZE, dtype=np.float32)
    gradient = np.stack([np.add.outer(x, x) / 2, np.add.outer(x, 255 - x) / 2, np.tile(x, (IMAGE_SIZE, 1))], axis=-1)
    images["gradient"] = Image.fromarray(gradient.astype(np.uint8))
    for name, image in images.items():
        image.save(out / f"parity-{name}.png")
    return images


def quantize(mlmodel, linear_only):
    """8-bit weights, per output channel. The image tower keeps its patch embedding (a conv) and position embeddings
    in 16-bit: 8-bit there drops its cosine to PyTorch from 0.999 to 0.93, for 1.6 MB saved."""
    weights = OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8", granularity="per_channel")
    config = OptimizationConfig(op_type_configs={"linear": weights}) if linear_only else OptimizationConfig(global_config=weights)
    return linear_quantize_weights(mlmodel, config)


def cosine(a, b):
    a, b = np.asarray(a, np.float64).ravel(), np.asarray(b, np.float64).ravel()
    return float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b)))


def compile_model(package, out):
    target = out / (package.stem + ".mlmodelc")
    if target.exists():
        shutil.rmtree(target)
    subprocess.run(["xcrun", "coremlcompiler", "compile", str(package), str(out)], check=True, stdout=subprocess.DEVNULL)
    return target


def size_mb(path):
    return sum(f.stat().st_size for f in path.rglob("*") if f.is_file()) / 1e6


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", type=pathlib.Path, required=True)
    parser.add_argument("--min-cosine", type=float, default=0.99)
    parser.add_argument("--keep-packages", action="store_true", help="keep the .mlpackage files next to the compiled models")
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)

    snapshot = pathlib.Path(snapshot_download(REPO, allow_patterns=["*.json", "model.safetensors", "tokenizer.model"]))
    config = json.loads((snapshot / "config.json").read_text())
    if config.get("model_type") != "siglip":
        sys.exit(f"{REPO} is model_type {config.get('model_type')!r}, not the fixed-resolution 'siglip'")
    model = SiglipModel.from_pretrained(snapshot, dtype=torch.float32).eval()
    processor = AutoProcessor.from_pretrained(snapshot)
    tokenizer = processor.tokenizer

    # PyTorch fp32 references, through the processor exactly as the model card uses it.
    images = test_images(out)
    with torch.no_grad():
        text_inputs = processor(text=[p for p in PROMPTS], padding="max_length", max_length=TEXT_LENGTH, return_tensors="pt")
        uses_mask = "attention_mask" in text_inputs
        reference_text = model.get_text_features(**text_inputs)
        reference_text = (reference_text / reference_text.norm(dim=-1, keepdim=True)).numpy()
        pixel_values = processor(images=list(images.values()), return_tensors="pt")["pixel_values"]
        reference_image = model.get_image_features(pixel_values=pixel_values)
        reference_image = (reference_image / reference_image.norm(dim=-1, keepdim=True)).numpy()
    token_ids = text_inputs["input_ids"].numpy().astype(np.int32)
    pad_id, eos_id = tokenizer.pad_token_id, tokenizer.eos_token_id
    logit_scale, logit_bias = float(model.logit_scale.exp()), float(model.logit_bias)

    # Trace and convert.
    with torch.no_grad():
        traced_image = torch.jit.trace(ImageTower(model).eval(), pixel_values[:1])
        traced_text = torch.jit.trace(TextTower(model, pad_id, uses_mask).eval(), text_inputs["input_ids"][:1])
    common = dict(convert_to="mlprogram", compute_precision=ct.precision.FLOAT16, minimum_deployment_target=ct.target.iOS18)
    image_model = ct.convert(
        traced_image,
        inputs=[ct.ImageType(name="image", shape=(1, 3, IMAGE_SIZE, IMAGE_SIZE), scale=1 / 127.5, bias=[-1, -1, -1], color_layout=ct.colorlayout.RGB)],
        outputs=[ct.TensorType(name="embedding")],
        **common,
    )
    text_model = ct.convert(
        traced_text,
        inputs=[ct.TensorType(name="input_ids", shape=(1, TEXT_LENGTH), dtype=np.int32)],
        outputs=[ct.TensorType(name="embedding")],
        **common,
    )
    packages = {}
    for name, mlmodel, description, linear_only in [
        ("SigLIP2Image", image_model, "SigLIP 2 B/16-256 image tower: 768-d L2-normalised embedding", True),
        ("SigLIP2Text", text_model, "SigLIP 2 B/16-256 text tower: 768-d L2-normalised embedding", False),
    ]:
        mlmodel = quantize(mlmodel, linear_only)
        mlmodel.short_description = description
        mlmodel.license = "Apache-2.0 (google/siglip2-base-patch16-256)"
        mlmodel.version = MODEL_ID
        package = out / f"{name}.mlpackage"
        if package.exists():
            shutil.rmtree(package)
        mlmodel.save(str(package))
        packages[name] = mlmodel

    # Core ML (8-bit) against PyTorch (fp32).
    image_cos = [cosine(packages["SigLIP2Image"].predict({"image": image})["embedding"], reference_image[i]) for i, image in enumerate(images.values())]
    text_cos = [cosine(packages["SigLIP2Text"].predict({"input_ids": token_ids[i : i + 1]})["embedding"], reference_text[i]) for i in range(len(PROMPTS))]
    print(f"cosine to PyTorch fp32: images {min(image_cos):.4f}..{max(image_cos):.4f}, text {min(text_cos):.4f}..{max(text_cos):.4f}")
    if min(image_cos + text_cos) < args.min_cosine:
        sys.exit(f"Core ML differs from PyTorch: lowest cosine {min(image_cos + text_cos):.4f} < {args.min_cosine}")
    # The CPU alone (the Simulator; an iPhone without the Neural Engine) computes 16-bit less exactly: reported, not gated.
    cpu = {name: ct.models.MLModel(m.get_spec(), weights_dir=m.weights_dir, compute_units=ct.ComputeUnit.CPU_ONLY) for name, m in packages.items()}
    cpu_image = [cosine(cpu["SigLIP2Image"].predict({"image": image})["embedding"], reference_image[i]) for i, image in enumerate(images.values())]
    cpu_text = [cosine(cpu["SigLIP2Text"].predict({"input_ids": token_ids[i : i + 1]})["embedding"], reference_text[i]) for i in range(len(PROMPTS))]
    print(f"CPU only: images {min(cpu_image):.4f}..{max(cpu_image):.4f}, text {min(cpu_text):.4f}..{max(cpu_text):.4f}")

    # Zero-shot sanity: the red square reads as red, the blue one as blue, in both.
    def zero_shot(image_embeddings, text_embeddings):
        logits = np.asarray(image_embeddings) @ np.asarray(text_embeddings[:2]).T * logit_scale + logit_bias
        return logits[0, 0] > logits[0, 1] and logits[1, 1] > logits[1, 0]
    coreml_image = [packages["SigLIP2Image"].predict({"image": images[n]})["embedding"].ravel() for n in ("red", "blue")]
    coreml_text = [packages["SigLIP2Text"].predict({"input_ids": token_ids[i : i + 1]})["embedding"].ravel() for i in range(2)]
    if not (zero_shot(reference_image[:2], reference_text) and zero_shot(coreml_image, coreml_text)):
        sys.exit("zero-shot check failed: red/blue squares don't match their prompts")
    print("zero-shot: red and blue squares match their prompts (PyTorch and Core ML)")

    compiled = {}
    for name in packages:
        compiled[name] = compile_model(out / f"{name}.mlpackage", out)
        if not args.keep_packages:
            shutil.rmtree(out / f"{name}.mlpackage")
        print(f"{compiled[name].name}: {size_mb(compiled[name]):.0f} MB")

    revision = snapshot.name
    (out / "model.json").write_text(json.dumps({
        "id": MODEL_ID, "dimension": int(reference_image.shape[1]), "imageSize": IMAGE_SIZE, "textLength": TEXT_LENGTH,
        "padTokenID": pad_id, "eosTokenID": eos_id, "lowercase": True, "logitScale": logit_scale, "logitBias": logit_bias,
        "imageModel": compiled["SigLIP2Image"].name, "textModel": compiled["SigLIP2Text"].name,
        "source": f"https://huggingface.co/{REPO}", "revision": revision, "license": "Apache-2.0",
        "weights": "int8 per-channel linear layers (image patch and position embeddings 16-bit)",
    }, indent=2) + "\n")
    (out / "parity.json").write_text(json.dumps({
        "model": MODEL_ID, "minCosine": args.min_cosine, "logitScale": logit_scale, "logitBias": logit_bias,
        "images": [{"file": f"parity-{n}.png", "embedding": [round(float(v), 6) for v in reference_image[i]]} for i, n in enumerate(images)],
        "prompts": [{"text": p, "tokenIDs": token_ids[i].tolist(), "embedding": [round(float(v), 6) for v in reference_text[i]]} for i, p in enumerate(PROMPTS)],
    }) + "\n")
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
