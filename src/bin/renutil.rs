use anyhow::Result;
use anyhow::anyhow;
use clap::{Parser, Subcommand};
use renkit::renutil::{cleanup, get_registry, install, launch, list, show, uninstall};
use renkit::version::Version;
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
        Ok(version) => Ok(version),
        Err(e) => Err(anyhow!("Invalid version: {} - {}", version, e)),
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
        #[arg(long, default_value_t = false)]
        nightly: bool,
    },
    /// Show information about a specific version of Ren'Py.
    Show {
        #[clap(value_parser = clap::builder::ValueParser::new(parse_version))]
        version: Version,
    },
    /// Launch the given version of Ren'Py.
    Launch {
        #[clap(short, long, value_parser = clap::builder::ValueParser::new(parse_version))]
        version: Option<Version>,
        args: Vec<String>,
        #[arg(long)]
        headless: bool,
        #[arg(short = 'd', long)]
        direct: bool,
        #[arg(short = 'c', long, default_value_t = false)]
        check_status: bool,
        #[arg(long)]
        no_auto_install: bool,
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
        Commands::List {
            online,
            num,
            nightly,
        } => list(&registry, *online, *num, *nightly).await?,
        Commands::Show { version } => show(&registry, version).await?,
        Commands::Launch {
            version,
            headless,
            direct,
            args,
            check_status,
            no_auto_install,
        } => {
            let (status, _stdout, _stderr) = launch(
                &registry,
                version.as_ref(),
                *headless,
                *direct,
                args,
                *check_status,
                !no_auto_install,
            )
            .await?;
            if !status.success() {
                std::process::exit(status.code().unwrap_or(1));
            }
            return Ok(());
        }
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
