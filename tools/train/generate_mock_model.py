"""
あおいレールプランナー - テスト用モックTFLiteモデル生成
flatbuffers の Builder API のみで TFLite v3 スキーマを直接エンコードする。
TensorFlow / tflite (リーダー) パッケージは不要。

依存:
    pip install flatbuffers

仕様:
    - 入力: [1, 320, 320, 3] UINT8 ("input")
    - 出力: [1, 14]          UINT8 ("output")
    - オペレータ: RESHAPE 1個（恒等的リシェイプ）
    - ファイル識別子: "TFL3"

出力:
    ../../frontend_flutter/assets/models/rail_detector.tflite
"""
import sys
from pathlib import Path
import flatbuffers

# Windows cp932 環境で絵文字を含む print が落ちないよう UTF-8 を強制
if sys.stdout.encoding and sys.stdout.encoding.lower() != "utf-8":
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass

# ---- TFLite スキーマ定数 ----
# (schema.fbs より)
TENSOR_TYPE_INT32 = 2
TENSOR_TYPE_UINT8 = 3
BUILTIN_OP_RESHAPE = 22
BUILTIN_OPT_RESHAPE = 17


# ---- 低レベル: テーブル構築ヘルパー ----
def _start(builder, n_fields):
    builder.StartObject(n_fields)


def _end(builder):
    return builder.EndObject()


def _add_offset(builder, slot, value):
    builder.PrependUOffsetTRelativeSlot(slot, value, 0)


def _add_uint(builder, slot, value):
    builder.PrependUint32Slot(slot, value, 0)


def _add_int(builder, slot, value, default=0):
    builder.PrependInt32Slot(slot, value, default)


def _add_byte(builder, slot, value, default=0):
    builder.PrependInt8Slot(slot, value, default)


def _add_bool(builder, slot, value, default=False):
    builder.PrependBoolSlot(slot, value, default)


def _vector_i32(builder, values):
    builder.StartVector(4, len(values), 4)
    for v in reversed(values):
        builder.PrependInt32(v)
    return builder.EndVector()


def _vector_u8(builder, values):
    builder.StartVector(1, len(values), 1)
    for v in reversed(values):
        builder.PrependByte(v)
    return builder.EndVector()


def _vector_offsets(builder, offsets):
    builder.StartVector(4, len(offsets), 4)
    for off in reversed(offsets):
        builder.PrependUOffsetTRelative(off)
    return builder.EndVector()


# ---- 各テーブル ----
def build_buffer(builder, data_bytes: bytes = b""):
    data_vec = _vector_u8(builder, list(data_bytes)) if data_bytes else None
    _start(builder, 3)
    if data_vec is not None:
        _add_offset(builder, 0, data_vec)
    return _end(builder)


def build_tensor(builder, shape, tensor_type, buffer_index, name):
    name_off = builder.CreateString(name)
    shape_vec = _vector_i32(builder, shape)
    _start(builder, 9)
    _add_offset(builder, 0, shape_vec)
    _add_byte(builder, 1, tensor_type)
    _add_uint(builder, 2, buffer_index)
    _add_offset(builder, 3, name_off)
    return _end(builder)


def build_reshape_options(builder, new_shape):
    new_shape_vec = _vector_i32(builder, new_shape)
    _start(builder, 2)
    _add_offset(builder, 0, new_shape_vec)
    return _end(builder)


def build_operator(builder, opcode_index, inputs, outputs, builtin_opts_type, builtin_opts):
    inputs_vec = _vector_i32(builder, inputs)
    outputs_vec = _vector_i32(builder, outputs)
    _start(builder, 11)  # Operator has many fields, we only set first few
    _add_uint(builder, 0, opcode_index)
    _add_offset(builder, 1, inputs_vec)
    _add_offset(builder, 2, outputs_vec)
    _add_byte(builder, 3, builtin_opts_type)
    _add_offset(builder, 4, builtin_opts)
    return _end(builder)


def build_subgraph(builder, tensors, inputs, outputs, operators, name):
    tensors_vec = _vector_offsets(builder, tensors)
    inputs_vec = _vector_i32(builder, inputs)
    outputs_vec = _vector_i32(builder, outputs)
    ops_vec = _vector_offsets(builder, operators)
    name_off = builder.CreateString(name)
    _start(builder, 5)
    _add_offset(builder, 0, tensors_vec)
    _add_offset(builder, 1, inputs_vec)
    _add_offset(builder, 2, outputs_vec)
    _add_offset(builder, 3, ops_vec)
    _add_offset(builder, 4, name_off)
    return _end(builder)


def build_operator_code(builder, builtin_code):
    _start(builder, 4)
    _add_byte(builder, 0, min(builtin_code, 127))   # deprecated_builtin_code
    _add_int(builder, 2, 1)                          # version
    _add_int(builder, 3, builtin_code)               # builtin_code (extended)
    return _end(builder)


def build_model(builder, op_codes, subgraphs, buffers, description):
    op_codes_vec = _vector_offsets(builder, op_codes)
    subgraphs_vec = _vector_offsets(builder, subgraphs)
    buffers_vec = _vector_offsets(builder, buffers)
    desc_off = builder.CreateString(description)
    _start(builder, 8)
    _add_uint(builder, 0, 3)                # version
    _add_offset(builder, 1, op_codes_vec)
    _add_offset(builder, 2, subgraphs_vec)
    _add_offset(builder, 3, desc_off)
    _add_offset(builder, 4, buffers_vec)
    return _end(builder)


# ---- メインビルド ----
def build_mock_tflite() -> bytes:
    """
    出力テンソルを定数バッファとして埋め込む。
    入力は読み捨てられ、常に14個のゼロを返す。
    実推論時に invoke() が成功する最小モック。
    """
    builder = flatbuffers.Builder(1024)

    # Buffer 0: 空（入力用、データなし）
    buf0 = build_buffer(builder)
    # Buffer 1: 出力定数 14 個の UINT8 ゼロ
    buf1 = build_buffer(builder, bytes([0] * 14))

    # Tensor 0 (input): [1, 320, 320, 3] UINT8 - 動的入力（buffer=0 空）
    t_in = build_tensor(builder, [1, 320, 320, 3], TENSOR_TYPE_UINT8, 0, "input")
    # Tensor 1 (output): [1, 14] UINT8 - 定数（buffer=1 に14個のゼロ）
    t_out = build_tensor(builder, [1, 14], TENSOR_TYPE_UINT8, 1, "output")

    # SubGraph: オペレータなし、出力は定数テンソル
    subgraph = build_subgraph(
        builder,
        tensors=[t_in, t_out],
        inputs=[0],
        outputs=[1],
        operators=[],
        name="mock_rail_detector",
    )

    # Model
    model = build_model(
        builder,
        op_codes=[],
        subgraphs=[subgraph],
        buffers=[buf0, buf1],
        description="mock rail detector for aoi rail planner",
    )

    builder.Finish(model, file_identifier=b"TFL3")
    return bytes(builder.Output())


def main():
    out = Path(__file__).parent.parent.parent / "frontend_flutter" / "assets" / "models" / "rail_detector.tflite"
    out.parent.mkdir(parents=True, exist_ok=True)

    data = build_mock_tflite()
    out.write_bytes(data)

    size_kb = len(data) / 1024
    print(f"✅ モックモデル生成: {out}")
    print(f"   サイズ: {size_kb:.2f} KB  ({len(data)} bytes)")
    print("⚠️  検出精度はありません。アプリ起動・パイプライン疎通確認専用。")
    print()
    print("実モデル訓練手順:")
    print("  1. data/images/train/ に学習画像を配置")
    print("  2. data/labels/train/ にYOLO形式ラベルを配置")
    print("  3. python train_yolo.py --epochs 100 --device cuda")
    print("  4. python convert_to_tflite.py")


if __name__ == "__main__":
    main()
