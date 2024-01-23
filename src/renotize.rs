use anyhow::{anyhow, Result};
use apple_codesign::{
    cli::{
        certificate_source::{CertificateDerSigningKey, PemSigningKey},
        config::SignConfig,
    },
    stapling::Stapler,
    CodeSignatureFlags, NotarizationUpload, Notarizer, SettingsScope, SigningSettings,
    UnifiedSigner,
};
use itertools::Itertools;
use plist::Value;
use std::{fs, io::Cursor, path::PathBuf, process::Command, time::Duration};

const APPLE_TIMESTAMP_URL: &str = "http://timestamp.apple.com/ts01";
const ENTITLEMENTS_PLIST: &str = r#"<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/></dict></plist>"#;

fn notarize_file(input_file: &PathBuf, app_store_key_file: &PathBuf) -> Result<()> {
    let notarizer = Notarizer::from_api_key(&app_store_key_file)?;

    println!("Uploading file to notarization service");
    let upload = notarizer.notarize_path(&input_file, Some(Duration::from_secs(1800)))?;

    match upload {
        NotarizationUpload::UploadId(data) => {
            println!("Notarization UUID: {}", data);
        }
        NotarizationUpload::NotaryResponse(data) => {
            println!("Notarization UUID: {}", data.data.id);
            let stapler = Stapler::new()?;
            stapler.staple_path(&input_file)?;
        }
    };

    Ok(())
}

pub fn unpack_app(
    input_file: &PathBuf,
    output_dir: &PathBuf,
    bundle_id: &String,
) -> Result<PathBuf> {
    if output_dir.exists() {
        std::fs::remove_dir_all(output_dir)?;
    }
    std::fs::create_dir_all(output_dir)?;

    let app_zip = fs::read(&input_file)?;
    zip_extract::extract(Cursor::new(app_zip), &output_dir, false)?;

    let mut app_path = None;
    for entry in fs::read_dir(output_dir)? {
        let entry = entry?;
        let path = entry.path();
        match path.extension() {
            Some(ext) => {
                if ext.to_string_lossy() == "app" {
                    let info_plist_path = path.join("Contents/Info.plist");
                    app_path = Some(path);
                    let mut info_plist = Value::from_file(&info_plist_path)?
                        .into_dictionary()
                        .ok_or(anyhow!("Info.plist is not a dictionary"))?;
                    info_plist.insert(
                        "CFBundleIdentifier".to_string(),
                        plist::Value::String(bundle_id.clone()),
                    );
                    Value::Dictionary(info_plist).to_file_xml(&info_plist_path)?;
                }
            }
            None => continue,
        };
    }

    Ok(app_path.unwrap())
}

pub fn sign_app(input_file: &PathBuf, key_file: &PathBuf, cert_file: &PathBuf) -> Result<()> {
    let pem_key = PemSigningKey {
        paths: vec![key_file.to_path_buf()],
    };

    let der_key = CertificateDerSigningKey {
        paths: vec![cert_file.to_path_buf()],
    };

    let mut sign_config = SignConfig::default();
    sign_config.signer.pem_path_key = Some(pem_key);
    sign_config.signer.certificate_der_key = Some(der_key);

    let mut settings = SigningSettings::default();

    let certs = sign_config.signer.resolve_certificates(false)?;
    certs.load_into_signing_settings(&mut settings)?;

    if let Some(team_id) = settings.set_team_id_from_signing_certificate() {
        println!("Inferred team ID: {team_id}");
    }

    settings.set_time_stamp_url(APPLE_TIMESTAMP_URL)?;

    settings.set_entitlements_xml(SettingsScope::Main, ENTITLEMENTS_PLIST)?;

    settings.set_code_signature_flags(SettingsScope::Main, CodeSignatureFlags::RUNTIME);

    for path in [
        "Contents/MacOS/zsync",
        "Contents/MacOS/zsyncmake",
        "Contents/MacOS/python",
        "Contents/MacOS/pythonw",
    ] {
        settings.set_code_signature_flags(
            SettingsScope::Path(path.to_string()),
            CodeSignatureFlags::RUNTIME,
        );
    }

    let signer = UnifiedSigner::new(settings);

    println!("Signing bundle at {:?}", input_file);
    signer.sign_path_in_place(input_file)?;

    Ok(())
}

pub fn notarize_app(input_file: &PathBuf, app_store_key_file: &PathBuf) -> Result<()> {
    notarize_file(input_file, app_store_key_file)
}

pub fn pack_dmg(
    input_file: &PathBuf,
    output_file: &PathBuf,
    volume_name: &Option<String>,
) -> Result<()> {
    let volume_name = match volume_name {
        Some(name) => name.clone(),
        None => {
            let input_file_name = input_file
                .file_name()
                .ok_or(anyhow!("Input file name is not valid UTF-8"))?
                .to_string_lossy();
            input_file_name
                .strip_suffix(".app")
                .ok_or(anyhow!("Input file name does not end with .app"))?
                .to_string()
        }
    };

    println!("Name: {}", volume_name);

    let mut cmd = Command::new("hdiutil");
    cmd.args([
        "create",
        "-fs",
        "HFS+",
        "-format",
        "UDBZ",
        "-ov",
        "-volname",
        &volume_name,
        "-srcfolder",
        &input_file.to_string_lossy(),
        &output_file.to_string_lossy(),
    ]);
    let status = cmd.status()?;

    if !status.success() {
        anyhow::bail!("Unable to create DMG.");
    }

    Ok(())
}

pub fn sign_dmg(input_file: &PathBuf, key_file: &PathBuf, cert_file: &PathBuf) -> Result<()> {
    let pem_key = PemSigningKey {
        paths: vec![key_file.to_path_buf()],
    };

    let der_key = CertificateDerSigningKey {
        paths: vec![cert_file.to_path_buf()],
    };

    let mut sign_config = SignConfig::default();
    sign_config.signer.pem_path_key = Some(pem_key);
    sign_config.signer.certificate_der_key = Some(der_key);

    let mut settings = SigningSettings::default();

    let certs = sign_config.signer.resolve_certificates(false)?;
    certs.load_into_signing_settings(&mut settings)?;

    if let Some(team_id) = settings.set_team_id_from_signing_certificate() {
        println!("Automatically setting team ID from signing certificate: {team_id}");
    }

    let signer = UnifiedSigner::new(settings);

    signer.sign_path_in_place(input_file)?;

    Ok(())
}

pub fn notarize_dmg(input_file: &PathBuf, app_store_key_file: &PathBuf) -> Result<()> {
    notarize_file(input_file, app_store_key_file)
}

pub fn status(uuid: &String, app_store_key_file: &PathBuf) -> Result<()> {
    let notarizer = Notarizer::from_api_key(&app_store_key_file)?;

    let log = match notarizer.fetch_notarization_log(&uuid) {
        Ok(log) => log,
        Err(_) => {
            println!("Status not available yet.");
            return Ok(());
        }
    };

    let status = match log.get("status") {
        Some(status) => status.as_str().unwrap(),
        None => "unknown",
    };
    println!("Status: {status}");

    match log.get("issues") {
        Some(issues) => {
            let issues = issues.as_array().unwrap().iter().map(|issue| {
                let issue = issue.as_object().unwrap();
                let message = issue.get("message").unwrap().as_str().unwrap();
                let doc_url = issue.get("docUrl").unwrap().as_str().unwrap();
                let path = issue.get("path").unwrap().as_str().unwrap();
                (message, doc_url, path)
            });

            for (key, group) in &issues.group_by(|(message, _, _)| *message) {
                println!("Error: {}", key);
                for (i, (_, doc_url, path)) in group.enumerate() {
                    if i == 0 {
                        println!("Documentation: {}\nAffected files:", doc_url);
                    }
                    println!("  - {}", path);
                }
            }
        }
        None => {}
    };

    Ok(())
}

pub fn full_run(
    input_file: &PathBuf,
    bundle_id: &String,
    key_file: &PathBuf,
    cert_file: &PathBuf,
    app_store_key_file: &PathBuf,
) -> Result<()> {
    let output_dir = input_file.with_extension("");
    println!("Unpacking app to {:?}", output_dir);
    let app_path = unpack_app(input_file, &output_dir, bundle_id)?;
    println!("Signing app at {:?}", app_path);
    sign_app(&app_path, key_file, cert_file)?;
    println!("Notarizing app at {:?}", app_path);
    notarize_app(&app_path, app_store_key_file)?;
    let dmg_path = app_path.with_extension("dmg");
    println!("Packing DMG to {:?}", dmg_path);
    pack_dmg(&app_path, &dmg_path, &None)?;
    println!("Signing DMG at {:?}", dmg_path);
    sign_dmg(&dmg_path, key_file, cert_file)?;
    println!("Notarizing DMG at {:?}", dmg_path);
    notarize_dmg(&dmg_path, app_store_key_file)?;
    println!("Done!");
    Ok(())
}
