"""
モックTFLiteモデルの構造検証スクリプト
tflite (リーダー) パッケージで読み戻し、入出力テンソル形状を表示する。
"""
import sys
from pathlib import Path
import tflite.Model

if sys.stdout.encoding and sys.stdout.encoding.lower() != "utf-8":
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass


def verify(model_path: Path) -> bool:
    if not model_path.exists():
        print(f"[NG] file not found: {model_path}")
        return False

    data = model_path.read_bytes()
    print(f"file       : {model_path}")
    print(f"size       : {len(data)} bytes")

    # ファイル識別子
    ident = data[4:8].decode("ascii", errors="replace")
    print(f"identifier : '{ident}'")
    if ident != "TFL3":
        print("[NG] file identifier is not TFL3")
        return False

    # スキーマで読み戻し（tflite v2系: モジュール直下に Model 関数群）
    try:
        model = tflite.Model.GetRootAsModel(data, 0)
    except Exception as exc:
        print(f"[NG] parse failed: {exc}")
        return False

    print(f"version    : {model.Version()}")
    desc = model.Description()
    if desc:
        print(f"description: {desc.decode('utf-8', errors='replace')}")

    print(f"buffers    : {model.BuffersLength()}")
    print(f"op codes   : {model.OperatorCodesLength()}")
    for i in range(model.OperatorCodesLength()):
        oc = model.OperatorCodes(i)
        print(f"  [{i}] builtin_code = {oc.BuiltinCode()}, version = {oc.Version()}")

    print(f"subgraphs  : {model.SubgraphsLength()}")
    for sg_idx in range(model.SubgraphsLength()):
        sg = model.Subgraphs(sg_idx)
        name = sg.Name().decode() if sg.Name() else ""
        print(f"  SubGraph[{sg_idx}] name='{name}'")
        print(f"    tensors  : {sg.TensorsLength()}")
        for i in range(sg.TensorsLength()):
            t = sg.Tensors(i)
            shape = [t.Shape(j) for j in range(t.ShapeLength())]
            tname = t.Name().decode() if t.Name() else ""
            print(f"      [{i}] name='{tname}' type={t.Type()} shape={shape} buffer={t.Buffer()}")

        inputs = [sg.Inputs(i) for i in range(sg.InputsLength())]
        outputs = [sg.Outputs(i) for i in range(sg.OutputsLength())]
        print(f"    inputs   : {inputs}")
        print(f"    outputs  : {outputs}")
        print(f"    operators: {sg.OperatorsLength()}")
        for i in range(sg.OperatorsLength()):
            op = sg.Operators(i)
            op_in = [op.Inputs(j) for j in range(op.InputsLength())]
            op_out = [op.Outputs(j) for j in range(op.OutputsLength())]
            print(f"      [{i}] opcode_index={op.OpcodeIndex()} inputs={op_in} outputs={op_out}")

    print()
    print("[OK] mock TFLite model is structurally valid")
    return True


if __name__ == "__main__":
    out = Path(__file__).parent.parent.parent / "frontend_flutter" / "assets" / "models" / "rail_detector.tflite"
    ok = verify(out)
    sys.exit(0 if ok else 1)
