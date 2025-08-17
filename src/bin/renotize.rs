use anyhow::Result;
use clap::{Parser, Subcommand};
use renkit::renotize::{
    full_run, notarize_app, notarize_dmg, pack_dmg, provision, sign_app, sign_dmg, status,
    unpack_app,
};
use std::path::PathBuf;

#[derive(Parser)]
#[command(author, version, about, long_about = None)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Utility method to provision required information for notarization using a step-by-step process.
    Provision,
    /// Unpacks the given ZIP file to the target directory.
    UnpackApp {
        input_file: PathBuf,
        output_dir: PathBuf,
        bundle_id: String,
    },
    /// Signs a .app bundle with the given Developer Identity.
    SignApp {
        input_file: PathBuf,
        key_file: PathBuf,
        cert_file: PathBuf,
    },
    /// Notarizes a .app bundle with the given Developer Account and bundle ID.
    NotarizeApp {
        input_file: PathBuf,
        app_store_key_file: PathBuf,
    },
    /// Packages a .app bundle into a .dmg file.
    PackDmg {
        input_file: PathBuf,
        output_file: PathBuf,
        volume_name: Option<String>,
    },
    /// Signs a .dmg file with the given Developer Identity.
    SignDmg {
        input_file: PathBuf,
        key_file: PathBuf,
        cert_file: PathBuf,
    },
    /// Notarizes a .dmg file with the given Developer Account and bundle ID.
    NotarizeDmg {
        input_file: PathBuf,
        app_store_key_file: PathBuf,
    },
    /// Checks the status of a notarization operation given its UUID.
    Status {
        uuid: String,
        app_store_key_file: PathBuf,
    },
    /// Fully notarize a given .app bundle, creating a signed and notarized artifact for distribution.
    FullRun {
        input_file: PathBuf,
        bundle_id: String,
        key_file: PathBuf,
        cert_file: PathBuf,
        app_store_key_file: PathBuf,
        /// Do not create a notarized ZIP bundle of the app.
        #[arg(long = "no-zip")]
        no_zip: bool,
        /// Do not create a notarized DMG image of the app.
        #[arg(long = "no-dmg")]
        no_dmg: bool,
    },
}

fn main() -> Result<()> {
    let cli = Cli::parse();

    match &cli.command {
        Commands::Provision => provision()?,
        Commands::UnpackApp {
            input_file,
            output_dir,
            bundle_id,
        } => {
            let _app_path = unpack_app(input_file, output_dir, bundle_id)?;
        }
        Commands::SignApp {
            input_file,
            key_file,
            cert_file,
        } => sign_app(input_file, key_file, cert_file)?,
        Commands::NotarizeApp {
            input_file,
            app_store_key_file,
        } => notarize_app(input_file, app_store_key_file)?,
        Commands::PackDmg {
            input_file,
            output_file,
            volume_name,
        } => pack_dmg(input_file, output_file, volume_name)?,
        Commands::SignDmg {
            input_file,
            key_file,
            cert_file,
        } => sign_dmg(input_file, key_file, cert_file)?,
        Commands::NotarizeDmg {
            input_file,
            app_store_key_file,
        } => notarize_dmg(input_file, app_store_key_file)?,
        Commands::Status {
            uuid,
            app_store_key_file,
        } => status(uuid, app_store_key_file)?,
        Commands::FullRun {
            input_file,
            bundle_id,
            key_file,
            cert_file,
            app_store_key_file,
            no_zip,
            no_dmg,
        } => full_run(
            input_file,
            bundle_id,
            key_file,
            cert_file,
            app_store_key_file,
            !no_zip,
            !no_dmg,
        )?,
    }

    Ok(())
}
