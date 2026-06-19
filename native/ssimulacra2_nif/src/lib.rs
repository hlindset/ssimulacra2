use fast_ssim2::compute_ssimulacra2;
use imgref::ImgRef;
use rustler::Binary;

#[rustler::nif]
fn nif_loaded() -> bool {
    true
}

/// Reinterpret a packed RGB888 byte slice as `ImgRef<[u8; 3]>` with stride = width.
/// Caller (Elixir) guarantees `bytes.len() == width * height * 3`.
fn as_imgref(bytes: &[u8], width: usize, height: usize) -> ImgRef<'_, [u8; 3]> {
    let pixels: &[[u8; 3]] = bytemuck::cast_slice(bytes);
    ImgRef::new(pixels, width, height)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn compare(
    reference: Binary,
    distorted: Binary,
    width: usize,
    height: usize,
) -> Result<f64, String> {
    let r = as_imgref(reference.as_slice(), width, height);
    let d = as_imgref(distorted.as_slice(), width, height);
    compute_ssimulacra2(r, d).map_err(|e| e.to_string())
}

rustler::init!("Elixir.Ssimulacra2.Native");
