use crate::version::Version;
use anyhow::anyhow;
use anyhow::Result;
use crossterm::{
    event,
    terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen},
    ExecutableCommand,
};
use lol_html::{element, HtmlRewriter, Settings};
use ratatui::layout::Constraint;
use ratatui::layout::Direction;
use ratatui::layout::Layout;
use ratatui::layout::Rect;
use ratatui::layout::Size;
use ratatui::style::Modifier;
use ratatui::style::Style;
use ratatui::widgets::Block;
use ratatui::widgets::Borders;
use ratatui::{
    prelude::{CrosstermBackend, Terminal},
    widgets::Paragraph,
};
use std::env;
use std::io::stdout;
use std::io::BufRead;
use std::io::BufReader;
use std::io::Cursor;
#[cfg(target_family = "unix")]
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::Command;
use std::process::ExitStatus;
use std::process::Stdio;
use std::sync::Arc;
use std::sync::Mutex;
use std::thread;
use std::time::Duration;
use std::{fs, marker::PhantomData, path::PathBuf};
use trauma::download::Download;
use trauma::downloader::DownloaderBuilder;
use tui_scrollview::ScrollView;
use tui_scrollview::ScrollViewState;
use tui_textarea::Input;
use tui_textarea::Key;
use tui_textarea::TextArea;
use wait_timeout::ChildExt;

pub trait InstanceState {}

pub struct Local;
pub struct Remote;

impl InstanceState for Local {}
impl InstanceState for Remote {}

pub struct Instance<S: InstanceState> {
    pub version: Version,
    _marker: PhantomData<S>,
}

impl<S: InstanceState> Instance<S> {
    pub fn new(version: Version) -> Self {
        Self {
            version,
            _marker: PhantomData,
        }
    }

    pub fn path(&self, registry: &PathBuf) -> PathBuf {
        let base_path = fs::canonicalize(registry).expect("Unable to canonicalize path.");
        base_path.join(self.version.to_string())
    }
}

impl Instance<Local> {
    pub fn architecture(&self) -> Result<&str> {
        let host_os = std::env::consts::OS;
        let architecture = std::env::consts::ARCH;

        match host_os {
            "windows" => match architecture {
                "x86_64" => {
                    if self.version < Version::from_str("7.4.0").unwrap() {
                        Ok("windows-x86_64")
                    } else if self.version < Version::from_str("8.0.0").unwrap() {
                        Ok("py2-windows-x86_64")
                    } else {
                        Ok("py3-windows-x86_64")
                    }
                }
                "x86" => {
                    if self.version < Version::from_str("7.4.0").unwrap() {
                        Ok("windows-i686")
                    } else if self.version < Version::from_str("8.0.0").unwrap() {
                        Ok("py2-windows-i686")
                    } else {
                        Ok("py3-windows-i686")
                    }
                }
                _ => panic!("Unsupported architecture: {}", architecture),
            },
            "linux" => match architecture {
                "x86_64" => {
                    if self.version < Version::from_str("7.4.0").unwrap() {
                        Ok("linux-x86_64")
                    } else if self.version < Version::from_str("8.0.0").unwrap() {
                        Ok("py2-linux-x86_64")
                    } else {
                        Ok("py3-linux-x86_64")
                    }
                }
                "x86" => {
                    if self.version < Version::from_str("7.4.0").unwrap() {
                        Ok("linux-i686")
                    } else if self.version < Version::from_str("8.0.0").unwrap() {
                        Ok("py2-linux-i686")
                    } else {
                        Ok("py3-linux-i686")
                    }
                }
                _ => panic!("Unsupported architecture: {}", architecture),
            },
            "macos" => {
                if self.version < Version::from_str("7.4.0").unwrap() {
                    Ok("darwin-x86_64")
                } else if self.version <= Version::from_str("7.4.11").unwrap() {
                    Ok("mac-x86_64")
                } else if self.version < Version::from_str("8.0.0").unwrap() {
                    Ok("py2-mac-x86_64")
                } else if self.version <= Version::from_str("8.0.3").unwrap() {
                    Ok("py3-mac-x86_64")
                } else {
                    Ok("py3-mac-universal")
                }
            }
            _ => Err(anyhow!("Unsupported OS: {}", host_os)),
        }
    }

    pub fn python(&self, registry: &PathBuf) -> Result<PathBuf> {
        let exe = match std::env::consts::OS {
            "windows" => "python.exe",
            _ => "python",
        };

        match self.architecture() {
            Ok(arch) => Ok(self.path(registry).join("lib").join(arch).join(exe)),
            Err(e) => Err(e),
        }
    }

    pub fn entrypoint(&self, registry: &PathBuf) -> PathBuf {
        self.path(registry).join("renpy.py")
    }
}

impl std::fmt::Display for Version {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Version {
                major,
                minor,
                patch,
                hotfix,
                nightly,
            } => {
                write!(f, "{}.{}.{}", major, minor, patch)?;
                if *hotfix > 0 {
                    write!(f, ".{}", hotfix)?;
                }
                if *nightly {
                    write!(f, "+nightly")?;
                }
                Ok(())
            }
        }
    }
}

pub fn get_registry(registry: Option<PathBuf>) -> PathBuf {
    let registry = registry
        .or_else(|| match home::home_dir() {
            Some(mut path) => {
                path.push(".renutil");
                Some(path)
            }
            None => None,
        })
        .expect("Unable to detect home directory.");

    if !registry.exists() {
        std::fs::create_dir_all(&registry).expect("Unable to create registry directory.");
    }

    registry
}

pub async fn get_available_versions(registry: &PathBuf, online: bool) -> Result<Vec<Version>> {
    let mut versions = vec![];

    if online {
        for (i, url) in ["https://nightly.renpy.org", "https://www.renpy.org/dl"]
            .iter()
            .enumerate()
        {
            let body = reqwest::get(*url).await?.text().await?;

            let mut rewriter = HtmlRewriter::new(
                Settings {
                    element_content_handlers: vec![element!("a[href]", |el| {
                        let href = el
                            .get_attribute("href")
                            .ok_or(anyhow!("Unable to get attribute."))?;
                        let href = match i {
                            0 => &href,
                            _ => href
                                .strip_suffix("/")
                                .ok_or(anyhow!("Unable to strip suffix."))?,
                        };

                        match Version::from_str(href) {
                            Ok(version) => {
                                versions.push(version);
                            }
                            Err(_) => {}
                        }

                        Ok(())
                    })],
                    ..Settings::default()
                },
                |_: &[u8]| {},
            );
            rewriter.write(body.as_bytes())?;
            rewriter.end()?;
        }
    } else {
        for entry in fs::read_dir(registry)? {
            let entry = entry?;
            let path = entry.path();
            let path = path
                .file_name()
                .ok_or(anyhow!("Unable to get file name."))?
                .to_str()
                .ok_or(anyhow!("Unable to get file name."))?;

            match Version::from_str(path) {
                Ok(version) => {
                    versions.push(version);
                }
                Err(_) => {}
            }
        }
    }

    Ok(versions)
}

pub async fn list(registry: &PathBuf, online: bool, num: usize, nightly: bool) -> Result<()> {
    let versions = get_available_versions(registry, online).await?;

    let mut versions = match online {
        true => versions
            .iter()
            .filter(|v| !v.nightly || nightly)
            .collect::<Vec<&Version>>(),
        false => versions.iter().collect::<Vec<&Version>>(),
    };

    versions.sort_by(|a, b| b.cmp(a));

    for version in versions.iter().take(num) {
        println!("{version}");
    }

    Ok(())
}

pub async fn show(registry: &PathBuf, version: &Version) -> Result<()> {
    if version.is_installed(registry) {
        println!("Version: {version}");
    } else {
        let versions = get_available_versions(registry, true).await?;
        if !versions.contains(version) {
            anyhow::bail!("{} is not a valid version of Ren'Py.", version);
        }
    }

    if version.is_installed(registry) {
        let instance = version
            .to_local(registry)
            .expect("Unable to get local instance.");

        println!("Installed: Yes");

        let location = instance.path(registry);
        let location = location.to_string_lossy();

        println!("Location: {location}");

        let architecture = instance
            .architecture()
            .expect("Unable to get architecture.");

        println!("Architecture: {architecture}");
    } else {
        println!("Installed: No");
    }
    println!("SDK URL: {}", version.sdk_url()?);
    println!("RAPT URL: {}", version.rapt_url()?);

    Ok(())
}

/*
fn deactivate(textarea: &mut TextArea<'_>) {
    textarea.set_cursor_line_style(Style::default());
    textarea.set_cursor_style(Style::default());
    textarea.set_block(
        Block::default()
            .borders(Borders::ALL)
            .style(Style::default().fg(Color::DarkGray))
            .title("Executing..."),
    );
}
*/

fn activate(textarea: &mut TextArea<'_>) {
    textarea.set_cursor_line_style(Style::default().add_modifier(Modifier::UNDERLINED));
    textarea.set_cursor_style(Style::default().add_modifier(Modifier::REVERSED));
    textarea.set_block(
        Block::default()
            .borders(Borders::ALL)
            .style(Style::default())
            .title("Ren'Py REPL"),
    );
}

fn exec_py(base_dir: PathBuf, code: &String) -> Result<()> {
    fs::write(base_dir.join("exec.py"), code).unwrap();

    let mut wait_time = 0;
    while !base_dir.join("exec.py").exists() {
        thread::sleep(Duration::from_millis(25));
        wait_time += 25;
        if wait_time > 200 {
            return Err(anyhow!("Timeout waiting for code to execute."));
        }
    }

    Ok(())
}

pub fn launch(
    registry: &PathBuf,
    version: &Version,
    headless: bool,
    direct: bool,
    args: &[String],
    check_status: bool,
    interactive: bool,
    code: Option<&String>,
) -> Result<(ExitStatus, String, String)> {
    let instance = version.to_local(registry)?;

    if interactive && version < &Version::from_str("8.3.0.24041102+nightly").unwrap() {
        anyhow::bail!("Interactive mode is only available in Ren'Py 8.3.1 and later.");
    }

    let python = instance.python(registry)?;
    let python = python.to_str().unwrap();

    let entrypoint = instance.entrypoint(registry);
    let entrypoint = entrypoint.to_str().unwrap();

    let rpy_log_val_orig = match std::env::var("RENPY_LOG_TO_STDOUT") {
        Ok(val) => Some(val),
        Err(_) => None,
    };
    std::env::set_var("RENPY_LOG_TO_STDOUT", "1");

    let mut cmd = Command::new(python);

    let cmd = cmd.stdout(Stdio::piped()).stderr(Stdio::piped());

    cmd.arg("-EO").arg(entrypoint);

    match direct {
        true => cmd.args(args),
        false => {
            let launcher_path = instance.path(registry).join("launcher");
            let launcher_path = launcher_path.to_str().unwrap();
            cmd.arg(launcher_path).args(args)
        }
    };

    if headless {
        std::env::set_var("SDL_AUDIODRIVER", "dummy");
        std::env::set_var("SDL_VIDEODRIVER", "dummy");
    }

    let mut terminal = None;
    if interactive && code.is_none() {
        stdout().execute(EnterAlternateScreen)?;
        enable_raw_mode()?;
        let mut t = Terminal::new(CrosstermBackend::new(stdout()))?;
        t.clear()?;
        terminal = Some(t);
    }

    let mut child = cmd.spawn()?;

    let child_stdout = child.stdout.take().unwrap();
    let child_stderr = child.stderr.take().unwrap();

    // We do some thread magic here to both print stdout and stderr as they come in,
    // as well as capturing them to return them once the process has exited.

    let bufread_stdout = BufReader::new(child_stdout);
    let bufread_stderr = BufReader::new(child_stderr);

    let has_code = code.is_some();

    let result_stdout = Arc::new(Mutex::new(vec![]));
    let result_stdout_clone = result_stdout.clone();
    let h_stdout = thread::spawn(move || {
        for line in bufread_stdout.lines() {
            let line = line.unwrap();
            if !interactive || has_code {
                println!("{line}");
            }
            let mut handle = result_stdout_clone.lock().unwrap();
            handle.push(line);
        }
    });

    let result_stderr = Arc::new(Mutex::new(vec![]));
    let result_stderr_clone = result_stderr.clone();
    let h_stderr = thread::spawn(move || {
        for line in bufread_stderr.lines() {
            let line = line.unwrap();
            if !interactive || has_code {
                eprintln!("{line}");
            }
            let mut handle = result_stderr_clone.lock().unwrap();
            handle.push(line);
        }
    });

    if interactive {
        if let Some(code) = &code {
            match exec_py(PathBuf::from(&args[0]), code) {
                Ok(_) => {}
                Err(e) => {
                    eprintln!("{e}");
                }
            }
        } else {
            let mut terminal = terminal.unwrap();

            let mut textarea = TextArea::default();
            activate(&mut textarea);

            let mut state_stdout = ScrollViewState::default();
            let mut state_stderr = ScrollViewState::default();

            let mut last_stdout_delta = 0;
            let mut last_stderr_delta = 0;

            loop {
                let stdout_logs = result_stdout.lock().unwrap().join("\n");
                let stderr_logs = result_stderr.lock().unwrap().join("\n");

                let stdout_len = result_stdout.lock().unwrap().len();
                let stderr_len = result_stderr.lock().unwrap().len();

                terminal.draw(|frame| {
                let area = frame.size();

                let outer_layout = Layout::default()
                    .direction(Direction::Vertical)
                    .constraints(vec![
                        Constraint::Percentage(70),
                        Constraint::Percentage(30),
                        Constraint::Length(3),
                    ])
                    .split(area);

                let inner_layout = Layout::default()
                    .direction(Direction::Horizontal)
                    .constraints(vec![Constraint::Percentage(50), Constraint::Percentage(50)])
                    .split(outer_layout[0]);

                frame.render_widget(
                    Paragraph::new("Ctrl-X: Execute | PageUp/PageDown: Scroll by page | Home/End: Scroll by line").block(Block::new().borders(Borders::ALL)),
                    outer_layout[2],
                );

                let widget = textarea.widget();
                frame.render_widget(widget, outer_layout[1]);

                let mut scroll_view_stdout = ScrollView::new(Size::new(100, stdout_len as u16));

                scroll_view_stdout.render_widget(
                    Paragraph::new(stdout_logs),
                    Rect::new(0, 0, 100, stdout_len as u16),
                );

                frame.render_stateful_widget(
                    scroll_view_stdout,
                    inner_layout[0],
                    &mut state_stdout,
                );

                let mut scroll_view_stderr = ScrollView::new(Size::new(100, stderr_len as u16));

                scroll_view_stderr.render_widget(
                    Paragraph::new(stderr_logs),
                    Rect::new(0, 0, 100, stderr_len as u16),
                );

                frame.render_stateful_widget(
                    scroll_view_stderr,
                    inner_layout[1],
                    &mut state_stderr,
                );

                let stdout_delta = stdout_len.saturating_sub(inner_layout[0].height as usize);
                if stdout_delta > 0 {
                    for _ in last_stdout_delta..stdout_delta {
                        state_stdout.scroll_down();
                    }
                }
                last_stdout_delta = stdout_delta;

                let stderr_delta = stderr_len.saturating_sub(inner_layout[1].height as usize);
                if stderr_delta > 0 {
                    for _ in last_stderr_delta..stderr_delta {
                        state_stderr.scroll_down();
                    }
                }
                last_stderr_delta = stderr_delta;
            })?;

                if event::poll(std::time::Duration::from_millis(8))? {
                    match crossterm::event::read()?.into() {
                        Input {
                            key: Key::Char('c'),
                            ctrl: true,
                            ..
                        } => {
                            child.kill()?;
                            break;
                        }
                        Input {
                            key: Key::Char('x'),
                            ctrl: true,
                            ..
                        } => match exec_py(PathBuf::from(&args[0]), &textarea.lines().join("\n")) {
                            Ok(_) => {}
                            Err(e) => {
                                eprintln!("{e}");
                                break;
                            }
                        },
                        Input {
                            key: Key::PageUp, ..
                        } => {
                            state_stdout.scroll_page_up();
                            state_stderr.scroll_page_up();
                        }
                        Input {
                            key: Key::PageDown, ..
                        } => {
                            state_stdout.scroll_page_down();
                            state_stderr.scroll_page_down();
                        }
                        Input { key: Key::Home, .. } => {
                            state_stdout.scroll_up();
                            state_stderr.scroll_up();
                        }
                        Input { key: Key::End, .. } => {
                            state_stdout.scroll_down();
                            state_stderr.scroll_down();
                        }
                        input => {
                            textarea.input(input);
                        }
                    }
                }

                match child.wait_timeout(Duration::from_millis(8)) {
                    Ok(Some(_)) => break,
                    Ok(None) => {}
                    Err(_) => {
                        println!("Error waiting for child process.");
                        break;
                    }
                };
            }
        }
    }

    h_stdout.join().unwrap();
    h_stderr.join().unwrap();

    if interactive && code.is_none() {
        stdout().execute(LeaveAlternateScreen)?;
        disable_raw_mode()?;
    }

    let status = child.wait()?;

    if check_status && !status.success() {
        anyhow::bail!(
            "Unable to launch Ren'Py: Status {}",
            status.code().unwrap_or(1)
        );
    }

    match rpy_log_val_orig {
        Some(val) => std::env::set_var("RENPY_LOG_TO_STDOUT", val),
        None => std::env::remove_var("RENPY_LOG_TO_STDOUT"),
    }

    let out_stdout = result_stdout.lock().unwrap().join("\n");
    let out_stderr = result_stderr.lock().unwrap().join("\n");

    Ok((status, out_stdout, out_stderr))
}

pub async fn install(
    registry: &PathBuf,
    version: &Version,
    no_cleanup: bool,
    force: bool,
    update_pickle: bool,
) -> Result<()> {
    let versions = get_available_versions(registry, true).await?;
    if !versions.contains(version) {
        anyhow::bail!("{} is not a valid version of Ren'Py.", version);
    }

    let java_home = match env::var("JAVA_HOME") {
        Ok(val) => PathBuf::from(val),
        Err(_) => {
            let jdk_version = match version >= &Version::from_str("8.2.0").unwrap() {
                true => "21",
                false => "8",
            };
            anyhow::bail!(
                "JAVA_HOME is not set. Please check if you need to install OpenJDK {jdk_version}"
            );
        }
    };

    if version.is_installed(registry) {
        if force {
            println!("Forcing uninstallation of existing version {}.", version);
            uninstall(registry, version)?;
        } else {
            return Err(anyhow!("Version {} is already installed.", version));
        }
    }

    let instance = version
        .to_remote(registry)
        .expect("Unable to get remote instance.");

    let base_path = instance.path(registry);

    fs::create_dir_all(&base_path).expect("Unable to create directory.");

    let sdk_url = version.sdk_url()?;
    let rapt_url = version.rapt_url()?;
    let steam_url = version.steam_url()?;
    let web_url = version.web_url()?;

    println!("Downloading Ren'Py {version}...");
    let downloads = vec![
        Download::new(&sdk_url, sdk_url.path_segments().unwrap().last().unwrap()),
        Download::new(&rapt_url, rapt_url.path_segments().unwrap().last().unwrap()),
        Download::new(
            &steam_url,
            steam_url.path_segments().unwrap().last().unwrap(),
        ),
        Download::new(&web_url, web_url.path_segments().unwrap().last().unwrap()),
    ];
    let downloader = DownloaderBuilder::new().directory(registry.clone()).build();
    downloader.download(&downloads).await;

    println!("Extracting SDK");

    let sdk_zip_path = registry.join(format!("renpy-{version}-sdk.zip"));

    let sdk_zip = fs::read(&sdk_zip_path)?;
    zip_extract::extract(Cursor::new(sdk_zip), &base_path, true)?;

    println!("Extracting RAPT");

    let rapt_zip_path = registry.join(format!("renpy-{version}-rapt.zip"));

    let rapt_zip = fs::read(&rapt_zip_path)?;
    zip_extract::extract(Cursor::new(rapt_zip), &base_path.join("rapt"), true)?;

    let steam_zip_path = registry.join(format!("renpy-{version}-steam.zip"));
    if steam_zip_path.exists() {
        println!("Extracting Steam support");

        let steam_zip = fs::read(&steam_zip_path)?;
        zip_extract::extract(Cursor::new(steam_zip), &base_path.join("lib"), true)?;
    }

    let web_zip_path = registry.join(format!("renpy-{version}-web.zip"));
    if web_zip_path.exists() {
        println!("Extracting Web support");

        let web_zip = fs::read(&web_zip_path)?;

        zip_extract::extract(Cursor::new(web_zip), &base_path.join("web"), true)?;
    }

    if !no_cleanup {
        println!("Cleaning up temporary files");
        fs::remove_file(sdk_zip_path).expect("Unable to remove SDK archive.");
        fs::remove_file(rapt_zip_path).expect("Unable to remove RAPT archive.");
        if steam_zip_path.exists() {
            fs::remove_file(steam_zip_path).expect("Unable to remove Steam archive.");
        }
        if web_zip_path.exists() {
            fs::remove_file(web_zip_path).expect("Unable to remove Web archive.");
        }
    }

    let instance = version.to_local(registry)?;

    let python = instance.python(registry)?;
    let python_parent = python.parent().ok_or(anyhow!("Unable to get parent."))?;

    #[cfg(target_family = "unix")]
    let paths = [
        python.clone(),
        python_parent.join("pythonw"),
        python_parent.join("renpy"),
        python_parent.join("zsync"),
        python_parent.join("zsyncmake"),
        base_path.join("rapt/prototype/gradlew"),
        base_path.join("rapt/project/gradlew"),
    ];

    #[cfg(target_family = "unix")]
    for path in paths.iter().filter(|p| p.exists()) {
        println!(
            "Setting executable permissions for {}.",
            path.to_string_lossy()
        );
        fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
    }

    let original_dir = env::current_dir()?;
    env::set_current_dir(base_path.join("rapt"))?;

    let keytool = java_home.join("bin/keytool");

    let android_keystore = Path::new("android.keystore");
    if !android_keystore.exists() {
        println!("Generating Android keystore");

        let mut cmd = Command::new(&keytool);
        cmd.args([
            "-genkey",
            "-keystore",
            "android.keystore",
            "-alias",
            "android",
            "-keyalg",
            "RSA",
            "-keysize",
            "2048",
            "-keypass",
            "android",
            "-storepass",
            "android",
            "-dname",
            "CN=renutil",
            "-validity",
            "20000",
        ]);
        let status = cmd.status()?;
        if !status.success() {
            anyhow::bail!("Unable to generate Android keystore.");
        }
    }

    let bundle_keystore = Path::new("bundle.keystore");
    if !bundle_keystore.exists() {
        println!("Generating Bundle keystore (reusing Android keystore)");

        fs::copy("android.keystore", "bundle.keystore")?;
    }

    println!("Patching SSL issue in RAPT");
    let interface_path = base_path.join("rapt/buildlib/rapt/interface.py");
    let content = fs::read_to_string(&interface_path)?;
    let mut lines: Vec<&str> = content.split('\n').collect();
    // insert as the second line, in case we have a __future__ import, which always goes first
    lines.insert(
        1,
        "import ssl; ssl._create_default_https_context = ssl._create_unverified_context",
    );
    fs::write(&interface_path, lines.join("\n"))?;

    println!("Installing RAPT");
    // in versions above 7.5.0, the RAPT installer tries to import renpy.compat
    // this is not in the path by default, and since PYTHONPATH is ignored, we
    // symlink it instead to make it visible during installation.
    if version >= &Version::from_str("7.5.0").unwrap() {
        #[cfg(target_family = "windows")]
        std::os::windows::fs::symlink_dir(base_path.join("renpy"), base_path.join("rapt/renpy"))?;
        #[cfg(target_family = "unix")]
        std::os::unix::fs::symlink(base_path.join("renpy"), base_path.join("rapt/renpy"))?;
    }

    env::set_var("RAPT_NO_TERMS", "1");

    let mut cmd = Command::new(&python);
    cmd.args(["-EO", "android.py", "installsdk"]);
    let status = cmd.status()?;
    if !status.success() {
        anyhow::bail!("Unable to install Android SDK.");
    }

    env::set_current_dir(original_dir)?;

    println!("Increasing Gradle RAM limit to 8Gb");
    let paths = [
        base_path.join("rapt/prototype/gradle.properties"),
        base_path.join("rapt/project/gradle.properties"),
    ];

    let re = regex::Regex::new(r"org\.gradle\.jvmargs=-Xmx(\d+)g").unwrap();
    for path in paths.iter().filter(|p| p.exists()) {
        let content = fs::read_to_string(&path)?;
        let content = re
            .replace_all(&content, "org.gradle.jvmargs=-Xmx8g")
            .to_string();
        fs::write(&path, content)?;
    }

    println!("Installing Android SDK");
    #[cfg(target_family = "windows")]
    let mut sdkmanager = base_path.join("rapt/Sdk/cmdline-tools/latest/bin/sdkmanager.exe");
    #[cfg(target_family = "unix")]
    let mut sdkmanager = base_path.join("rapt/Sdk/cmdline-tools/latest/bin/sdkmanager");

    // On older versions of Ren'Py, the SDK manager is in a different location.
    if !sdkmanager.exists() {
        #[cfg(target_family = "windows")]
        let new_sdkmanager = base_path.join("rapt/Sdk/tools/bin/sdkmanager.exe");
        #[cfg(target_family = "unix")]
        let new_sdkmanager = base_path.join("rapt/Sdk/tools/bin/sdkmanager");
        sdkmanager = new_sdkmanager;
    }

    let mut cmd = Command::new(&sdkmanager);
    cmd.arg("build-tools;29.0.2");
    let status = cmd.status()?;
    if !status.success() {
        anyhow::bail!("Unable to install Android SDK build tools.");
    }

    if update_pickle {
        println!("Increasing default pickle protocol from 2 to 5");
        let pickle_path = base_path.join("renpy/compat/pickle.py");
        let content = fs::read_to_string(&pickle_path)?;
        fs::write(
            &pickle_path,
            content.replace("PROTOCOL = 2", "PROTOCOL = 5"),
        )?;
    }

    Ok(())
}

pub fn cleanup(registry: &PathBuf, version: &Version) -> Result<()> {
    let instance = version.to_local(registry)?;

    let path = instance.path(registry);

    let paths = [
        path.join("tmp"),
        path.join("rapt/assets"),
        path.join("rapt/bin"),
        path.join("rapt/project/app/build"),
        path.join("rapt/project/app/src/main/assets"),
    ];

    for path in paths.iter().filter(|p| p.exists()) {
        println!("Cleaning up {}", path.to_string_lossy());
        fs::remove_dir_all(path)?;
    }

    Ok(())
}

pub fn uninstall(registry: &PathBuf, version: &Version) -> Result<()> {
    let instance = version.to_local(registry)?;

    let path = instance.path(registry);

    fs::remove_dir_all(path)?;

    Ok(())
}
