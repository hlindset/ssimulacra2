use fast_ssim2::{compute_ssimulacra2, Ssimulacra2Reference};
use imgref::ImgRef;
use rustler::{Binary, ResourceArc};

#[rustler::nif]
fn nif_loaded() -> bool {
    true
}

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

/// Precomputed reference, owned by the BEAM and handed back as an opaque resource.
struct ReferenceResource {
    inner: Ssimulacra2Reference,
}

#[rustler::resource_impl]
impl rustler::Resource for ReferenceResource {}

#[rustler::nif(schedule = "DirtyCpu")]
fn reference_new(
    source: Binary,
    width: usize,
    height: usize,
) -> Result<ResourceArc<ReferenceResource>, String> {
    let src = as_imgref(source.as_slice(), width, height);
    let inner = Ssimulacra2Reference::new(src).map_err(|e| e.to_string())?;
    Ok(ResourceArc::new(ReferenceResource { inner }))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn reference_compare(
    reference: ResourceArc<ReferenceResource>,
    distorted: Binary,
    width: usize,
    height: usize,
) -> Result<f64, String> {
    let d = as_imgref(distorted.as_slice(), width, height);
    reference.inner.compare(d).map_err(|e| e.to_string())
}

rustler::init!("Elixir.Ssimulacra2.Native");
