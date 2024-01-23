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
use plist::Value;
use std::{fs, io::Cursor, path::PathBuf, process::Command, time::Duration};

const ENTITLEMENTS_PLIST: &str = r#"<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/></dict></plist>"#;

pub fn unpack_app(input_file: &PathBuf, output_dir: &PathBuf, bundle_id: &String) -> Result<()> {
    if output_dir.exists() {
        std::fs::remove_dir_all(output_dir)?;
    }
    std::fs::create_dir_all(output_dir)?;

    let app_zip = fs::read(&input_file)?;
    zip_extract::extract(Cursor::new(app_zip), &output_dir, false)?;

    for entry in fs::read_dir(output_dir)? {
        let entry = entry?;
        let path = entry.path();
        match path.extension() {
            Some(ext) => {
                if ext.to_string_lossy() == "app" {
                    let info_plist_path = path.join("Contents/Info.plist");
                    let mut info_plist = Value::from_file(&info_plist_path)?
                        .into_dictionary()
                        .ok_or(anyhow!("Info.plist is not a dictionary"))?;
                    info_plist.insert(
                        "CFBundleIdentifier".to_string(),
                        plist::Value::String(bundle_id.clone()),
                    );
                    println!("Writing new Info.plist to {:?}", info_plist_path);
                    Value::Dictionary(info_plist).to_file_xml(&info_plist_path)?;
                }
            }
            None => continue,
        };
    }

    Ok(())
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
        println!("Automatically setting team ID from signing certificate: {team_id}");
    }

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
    signer.sign_path(input_file, "out/signed.app")?;

    Ok(())
}

pub fn notarize_app(input_file: &PathBuf, app_store_key_file: &PathBuf) -> Result<()> {
    let notarizer = Notarizer::from_api_key(&app_store_key_file)?;

    let upload = notarizer.notarize_path(&input_file, Some(Duration::from_secs(600)))?;

    match upload {
        NotarizationUpload::UploadId(_) => {
            panic!("NotarizationUpload::UploadId should not be returned if we waited successfully");
        }
        NotarizationUpload::NotaryResponse(_) => {
            let stapler = Stapler::new()?;
            stapler.staple_path(&input_file)?;
        }
    };

    Ok(())
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
