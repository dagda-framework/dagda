# Dagda Canvas Slide (`examples/canvas-slide`)

Native SDL3 app demonstrating Dagda's fixed-aspect canvas layout (`dagda.resolve_canvas`), canvas-clipped painting in `dagda/sdlhost`, and inspector window + canvas coordinate reporting in `dagda/driver`.

## Build, run, and verify

From the repository root:

```sh
mkdir -p build
./scripts/odin.sh build examples/canvas-slide -collection:dagda=. -out:build/canvas-slide
./scripts/odin.sh build examples/dagda-client -collection:dagda=. -out:build/dagda-client

# Run standalone or at a custom viewport size
./build/canvas-slide --size 640x480

# Run the two-viewport PNG pixel vs. inspected bounds acceptance test
python3 examples/canvas-slide/tests/acceptance_test.py build/canvas-capture
```
