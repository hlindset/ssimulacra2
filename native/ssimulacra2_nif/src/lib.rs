use almost_enough::SyncStopper;
use fast_ssim2::{compute_ssimulacra2, Ssimulacra2Reference, ToLinearRgb};
use imgref::{ImgRef, ImgVec};
use rustler::{Atom, Binary, ResourceArc};

mod atoms {
    rustler::atoms! {
        ok,
        rgb888,
        rgb16,
        linear_rgb,
        gray8,
        linear_gray,
    }
}

#[rustler::nif]
fn nif_loaded() -> bool {
    true
}

struct StopResource {
    stopper: SyncStopper,
}

#[rustler::resource_impl]
impl rustler::Resource for StopResource {}

/// Create a fresh, live cancellation token. Regular (non-dirty) NIF.
#[rustler::nif]
fn token_new() -> ResourceArc<StopResource> {
    ResourceArc::new(StopResource {
        stopper: SyncStopper::new(),
    })
}

/// Trip a cancellation token. Regular NIF — runs instantly on a normal
/// scheduler, so it can cancel a token while a dirty `compare` blocks.
#[rustler::nif]
fn token_cancel(token: ResourceArc<StopResource>) -> Atom {
    token.stopper.cancel();
    atoms::ok()
}

enum Format {
    Rgb888,
    Rgb16,
    LinearRgb,
    Gray8,
    LinearGray,
}

impl Format {
    fn from_atom(a: Atom) -> Result<Self, String> {
        if a == atoms::rgb888() {
            Ok(Format::Rgb888)
        } else if a == atoms::rgb16() {
            Ok(Format::Rgb16)
        } else if a == atoms::linear_rgb() {
            Ok(Format::LinearRgb)
        } else if a == atoms::gray8() {
            Ok(Format::Gray8)
        } else if a == atoms::linear_gray() {
            Ok(Format::LinearGray)
        } else {
            Err("unknown format".to_string())
        }
    }
}

// Per-format builders. 8-bit element types (align 1) borrow the binary
// directly. Multi-byte element types are copied into an owned, aligned Vec
// via from_ne_bytes: BEAM (sub-)binaries are not guaranteed to be 2-/4-byte
// aligned, and bytemuck::cast_slice would panic on a misaligned slice.

fn rgb888(b: &[u8], w: usize, h: usize) -> ImgRef<'_, [u8; 3]> {
    ImgRef::new(bytemuck::cast_slice(b), w, h)
}

fn gray8(b: &[u8], w: usize, h: usize) -> ImgRef<'_, u8> {
    ImgRef::new(b, w, h)
}

fn rgb16(b: &[u8], w: usize, h: usize) -> ImgVec<[u16; 3]> {
    let px: Vec<[u16; 3]> = b
        .chunks_exact(6)
        .map(|c| {
            [
                u16::from_ne_bytes([c[0], c[1]]),
                u16::from_ne_bytes([c[2], c[3]]),
                u16::from_ne_bytes([c[4], c[5]]),
            ]
        })
        .collect();
    ImgVec::new(px, w, h)
}

fn linear_rgb(b: &[u8], w: usize, h: usize) -> ImgVec<[f32; 3]> {
    let px: Vec<[f32; 3]> = b
        .chunks_exact(12)
        .map(|c| {
            [
                f32::from_ne_bytes([c[0], c[1], c[2], c[3]]),
                f32::from_ne_bytes([c[4], c[5], c[6], c[7]]),
                f32::from_ne_bytes([c[8], c[9], c[10], c[11]]),
            ]
        })
        .collect();
    ImgVec::new(px, w, h)
}

fn linear_gray(b: &[u8], w: usize, h: usize) -> ImgVec<f32> {
    let px: Vec<f32> = b
        .chunks_exact(4)
        .map(|c| f32::from_ne_bytes([c[0], c[1], c[2], c[3]]))
        .collect();
    ImgVec::new(px, w, h)
}

fn score<S: ToLinearRgb, D: ToLinearRgb>(s: S, d: D) -> Result<f64, String> {
    compute_ssimulacra2(s, d).map_err(|e| e.to_string())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn compare(
    reference: Binary,
    distorted: Binary,
    width: usize,
    height: usize,
    format: Atom,
) -> Result<f64, String> {
    let (r, d, w, h) = (reference.as_slice(), distorted.as_slice(), width, height);
    match Format::from_atom(format)? {
        Format::Rgb888 => score(rgb888(r, w, h), rgb888(d, w, h)),
        Format::Gray8 => score(gray8(r, w, h), gray8(d, w, h)),
        Format::Rgb16 => {
            let (a, b) = (rgb16(r, w, h), rgb16(d, w, h));
            score(a.as_ref(), b.as_ref())
        }
        Format::LinearRgb => {
            let (a, b) = (linear_rgb(r, w, h), linear_rgb(d, w, h));
            score(a.as_ref(), b.as_ref())
        }
        Format::LinearGray => {
            let (a, b) = (linear_gray(r, w, h), linear_gray(d, w, h));
            score(a.as_ref(), b.as_ref())
        }
    }
}

struct ReferenceResource {
    inner: Ssimulacra2Reference,
}

#[rustler::resource_impl]
impl rustler::Resource for ReferenceResource {}

fn build_reference<S: ToLinearRgb>(src: S) -> Result<ResourceArc<ReferenceResource>, String> {
    let inner = Ssimulacra2Reference::new(src).map_err(|e| e.to_string())?;
    Ok(ResourceArc::new(ReferenceResource { inner }))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn reference_new(
    source: Binary,
    width: usize,
    height: usize,
    format: Atom,
) -> Result<ResourceArc<ReferenceResource>, String> {
    let (s, w, h) = (source.as_slice(), width, height);
    match Format::from_atom(format)? {
        Format::Rgb888 => build_reference(rgb888(s, w, h)),
        Format::Gray8 => build_reference(gray8(s, w, h)),
        Format::Rgb16 => build_reference(rgb16(s, w, h).as_ref()),
        Format::LinearRgb => build_reference(linear_rgb(s, w, h).as_ref()),
        Format::LinearGray => build_reference(linear_gray(s, w, h).as_ref()),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn reference_compare(
    reference: ResourceArc<ReferenceResource>,
    distorted: Binary,
    width: usize,
    height: usize,
    format: Atom,
) -> Result<f64, String> {
    let (d, w, h) = (distorted.as_slice(), width, height);
    let r = &reference.inner;
    match Format::from_atom(format)? {
        Format::Rgb888 => r.compare(rgb888(d, w, h)).map_err(|e| e.to_string()),
        Format::Gray8 => r.compare(gray8(d, w, h)).map_err(|e| e.to_string()),
        Format::Rgb16 => r.compare(rgb16(d, w, h).as_ref()).map_err(|e| e.to_string()),
        Format::LinearRgb => r
            .compare(linear_rgb(d, w, h).as_ref())
            .map_err(|e| e.to_string()),
        Format::LinearGray => r
            .compare(linear_gray(d, w, h).as_ref())
            .map_err(|e| e.to_string()),
    }
}

rustler::init!("Elixir.Ssimulacra2.Native");
