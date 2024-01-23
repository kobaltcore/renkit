use anyhow::anyhow;
use anyhow::Result;
use clap::{Parser, Subcommand};
use renkit::common::Version;
use renkit::renutil::{cleanup, get_registry, install, launch, list, show, uninstall};
use std::path::PathBuf;

#[derive(Parser)]
#[command(author, version, about, long_about = None)]
struct Cli {
    /// The path to the registry directory to use. [default: ~/.renutil]
    #[arg(short = 'r', long)]
    registry: Option<PathBuf>,
    #[command(subcommand)]
    command: Commands,
}

fn parse_version(version: &str) -> Result<Version> {
    match Version::from_str(version) {
        Some(version) => Ok(version),
        None => Err(anyhow!("Invalid version: {}", version)),
    }
}

#[derive(Subcommand)]
enum Commands {
    /// List all available versions of Ren'Py, either local or remote.
    List {
        #[arg(short = 'o', long, default_value_t = false)]
        online: bool,
        #[arg(short = 'n', long, default_value_t = 5)]
        num: usize,
    },
    /// Show information about a specific version of Ren'Py.
    Show {
        #[clap(value_parser = clap::builder::ValueParser::new(parse_version))]
        version: Version,
    },
    /// Launch the given version of Ren'Py.
    Launch {
        #[clap(value_parser = clap::builder::ValueParser::new(parse_version))]
        version: Version,
        args: Vec<String>,
        #[arg(long)]
        headless: bool,
        #[arg(short = 'd', long)]
        direct: bool,
    },
    /// Install the given version of Ren'Py.
    Install {
        #[clap(value_parser = clap::builder::ValueParser::new(parse_version))]
        version: Version,
        #[arg(short = 'n', long)]
        no_cleanup: bool,
        #[arg(short = 'f', long)]
        force: bool,
        #[arg(short = 'u', long)]
        update_pickle: bool,
    },
    /// Cleans up temporary directories for the given version of Ren'Py.
    Clean {
        #[clap(value_parser = clap::builder::ValueParser::new(parse_version))]
        version: Version,
    },
    #[command(alias = "remove")]
    /// Uninstalls the given version of Ren'Py.
    Uninstall {
        #[clap(value_parser = clap::builder::ValueParser::new(parse_version))]
        version: Version,
    },
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();

    let registry = get_registry(cli.registry);

    match &cli.command {
        Commands::List { online, num } => list(&registry, *online, *num).await?,
        Commands::Show { version } => show(&registry, version).await?,
        Commands::Launch {
            version,
            headless,
            direct,
            args,
        } => launch(&registry, version, *headless, *direct, args)?,
        Commands::Install {
            version,
            no_cleanup,
            force,
            update_pickle,
        } => install(&registry, version, *no_cleanup, *force, *update_pickle).await?,
        Commands::Clean { version } => cleanup(&registry, version)?,
        Commands::Uninstall { version } => uninstall(&registry, version)?,
    }

    Ok(())
}
