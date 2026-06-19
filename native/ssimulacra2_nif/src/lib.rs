#[rustler::nif]
fn nif_loaded() -> bool {
    true
}

rustler::init!("Elixir.Ssimulacra2.Native");
