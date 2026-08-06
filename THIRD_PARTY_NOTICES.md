# Third-party notices

## Parrot

WhisprGo's interaction model and native macOS architecture were inspired by
`digimata/parrot`, which is distributed under the MIT License.

Copyright (c) 2026 Andrew Jones

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
of the Software, and to permit persons to whom the Software is furnished to do
so, subject to the condition that its copyright and permission notice are
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Argmax open-source SDK / WhisperKit

The Swift package dependency includes its own license and notices. See
<https://github.com/argmaxinc/argmax-oss-swift> for the license text and bundled
third-party attributions for each resolved version.

## FluidAudio

Parakeet Core ML inference uses FluidAudio, distributed under the Apache
License 2.0. See <https://github.com/FluidInference/FluidAudio> for its license
and bundled third-party notices.

## NVIDIA Parakeet TDT 0.6B v3

The default speech-recognition model is NVIDIA's `parakeet-tdt-0.6b-v3`,
downloaded in a Core ML conversion maintained by FluidInference. The original
model is licensed under CC BY 4.0:
<https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3>. WhisprGo does not
modify the model weights.

## MLX Swift and MLX Swift LM

On-device Pro cleanup uses Apple's MLX Swift and the MLX Swift LM model
implementations. The Swift package dependencies include their MIT license texts.
See <https://github.com/ml-explore/mlx-swift> and
<https://github.com/ml-explore/mlx-swift-lm>.

## Swift Hugging Face and Swift Transformers

The local cleanup model downloader and tokenizer use Hugging Face's Swift
packages. Their package distributions include the applicable license texts.
See <https://github.com/huggingface/swift-huggingface> and
<https://github.com/huggingface/swift-transformers>.

## Gemma 4 E2B

The optional on-device cleanup model is Unsloth's 4-bit MLX conversion of
Gemma 4 E2B Instruct. It is downloaded only after the user chooses On Device
cleanup and accepts the storage and memory warning. Model details and license:
<https://huggingface.co/unsloth/gemma-4-E2B-it-UD-MLX-4bit>.
