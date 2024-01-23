use anyhow::Result;
use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(author, version, about, long_about = None)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Utility method to provision required information for notarization using a step-by-step process.
    Provision {},
    /// Unpacks the given ZIP file to the target directory.
    UnpackApp {},
    /// Signs a .app bundle with the given Developer Identity.
    SignApp {},
    /// Notarizes a .app bundle with the given Developer Account and bundle ID.
    NotarizeApp {},
    /// Packages a .app bundle into a .dmg file.
    PackDmg {},
    /// Signs a .dmg file with the given Developer Identity.
    SignDmg {},
    /// Notarizes a .dmg file with the given Developer Account and bundle ID.
    NotarizeDmg {},
    /// Checks the status of a notarization operation given its UUID.
    Status {},
    /// Fully notarize a given .app bundle, creating a signed and notarized artifact for distribution.
    FullRun {},
}

#[tokio::main]
async fn main() -> Result<()> {
    let _cli = Cli::parse();

    // match &cli.command {
    //     Commands::Build {
    //         input_dir,
    //         output_dir,
    //         config_path,
    //     } => build(input_dir, output_dir, config_path.clone()).await?,
    // }

    Ok(())
}
