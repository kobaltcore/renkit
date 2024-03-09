use anyhow::{anyhow, Result};
use apple_codesign::{
    cli::{
        certificate_source::{CertificateDerSigningKey, CertificateSource, PemSigningKey},
        config::SignConfig,
    },
    stapling::Stapler,
    AppleCodesignError, CodeSignatureFlags, NotarizationUpload, Notarizer, SettingsScope,
    SigningSettings, UnifiedSigner,
};
use itertools::Itertools;
use plist::Value;
use rsa::{pkcs1::EncodeRsaPrivateKey, RsaPrivateKey};
use std::{fs, io::Cursor, path::PathBuf, process::Command, time::Duration};
use x509_certificate::X509CertificateBuilder;

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
        Some(issues) => match issues {
            serde_json::Value::Array(_) => {
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
            _ => {}
        },
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

pub fn provision() -> Result<()> {
    let cert_dir = PathBuf::from("certificates");
    fs::create_dir_all(&cert_dir)?;

    let mut rng = rand::thread_rng();
    let priv_key = RsaPrivateKey::new(&mut rng, 2048)?;

    let data = priv_key.to_pkcs1_pem(rsa::pkcs8::LineEnding::LF)?;
    let private_key_path = cert_dir.join("private-key.pem");
    fs::write(&private_key_path, data)?;

    let pem_key = PemSigningKey {
        paths: vec![private_key_path],
    };

    let mut cert_source = CertificateSource::default();
    cert_source.pem_path_key = Some(pem_key);

    let certs = cert_source.resolve_certificates(false)?;
    let private_key = certs.private_key()?;

    let mut builder = X509CertificateBuilder::default();
    builder
        .subject()
        .append_common_name_utf8_string("Apple Code Signing CSR")
        .map_err(|e| AppleCodesignError::CertificateBuildError(format!("{e:?}")))?;

    println!("Generating CSR. You may be prompted to enter credentials to unlock the signing key.");
    let pem = builder
        .create_certificate_signing_request(private_key.as_key_info_signer())?
        .encode_pem()?;

    let csr_path = cert_dir.join("csr.pem");

    std::fs::write(csr_path, pem.as_bytes())?;

    println!("This step should be completed in the browser.");
    println!("Press 'Enter' to open the browser and continue.");

    let mut input = String::new();
    std::io::stdin().read_line(&mut input)?;

    webbrowser::open("https://developer.apple.com/account/resources/certificates/add")?;

    println!("1. Select 'Developer ID Application' as the certificate type");
    println!("2. Click 'Continue'");
    println!("3. Select the G2 Sub-CA (Xcode 11.4.1 or later) Profile Type");
    println!("4. Select 'csr.pem' using the file picker");
    println!("5. Click 'Continue'");
    println!("6. Click the 'Download' button to download your certificate");
    println!("7. Save the certificate next to the private-key.pem and csr.pem files:");
    println!(
        "     {}/developerID_application.cer",
        cert_dir.to_string_lossy()
    );

    println!("Press 'Enter' when you have saved the certificate");

    let mut input = String::new();
    std::io::stdin().read_line(&mut input)?;

    let cert_file = cert_dir.join("developerID_application.cer");
    loop {
        if cert_file.exists() {
            break;
        }
        println!("Certificate not found. Press 'Enter' when you have saved the certificate.");
        println!("Make sure to name the file 'developerID_application.cer' and save it next to the private-key.pem and csr.pem files.");
        let mut input = String::new();
        std::io::stdin().read_line(&mut input)?;
    }

    println!("Success!");

    println!("This step should be completed in the browser.");
    println!("Press 'Enter' to open the browser and continue.");

    let mut input = String::new();
    std::io::stdin().read_line(&mut input)?;

    webbrowser::open("https://appstoreconnect.apple.com/access/users")?;

    println!("1. Click on 'Keys'");
    println!(
        "2. If this is your first time, click on 'Request Access' and wait until it is granted"
    );
    println!("3. Click on 'Generate API Key'");
    println!("4. Enter a name for the key");
    println!("5. For Access, select 'Developer'");
    println!("6. Click on 'Generate'");
    println!("7. Copy the Issuer ID and enter it here: ('Enter' to confirm)");

    let mut issuer_id = String::new();

    loop {
        std::io::stdin().read_line(&mut issuer_id)?;

        if issuer_id.len() > 1 {
            break;
        }

        println!("Issuer ID can not be empty, please try again.");
    }

    println!("8. Copy the Key ID and enter it here: ('Enter' to confirm)");

    let mut key_id = String::new();

    loop {
        std::io::stdin().read_line(&mut key_id)?;

        if key_id.len() > 1 {
            break;
        }

        println!("Key ID can not be empty, please try again.");
    }

    println!(
        "9. Next to the entry of the newly-created key in the list, click on 'Download API Key'"
    );
    println!("10. In the following pop-up, Click on 'Download'");
    println!("11. Save the downloaded .p8 file next to the private-key.pem and csr.pem files.");

    let app_store_cert_path;

    loop {
        match fs::read_dir(&cert_dir)?.find_map(|entry| {
            let entry = entry.unwrap();
            let path = entry.path();
            match path.extension() {
                Some(ext) => {
                    if ext == "p8" {
                        Some(path)
                    } else {
                        None
                    }
                }
                None => None,
            }
        }) {
            Some(path) => {
                app_store_cert_path = path;
                break;
            }
            None => {
                println!("Key file not found. Press 'Enter' when you have saved the key file.");
                println!(
                    "Make sure to save the file next to the private-key.pem and csr.pem files."
                );
                let mut input = String::new();
                std::io::stdin().read_line(&mut input)?;
            }
        }
    }

    let unified = app_store_connect::UnifiedApiKey::from_ecdsa_pem_path(
        &issuer_id,
        &key_id,
        &app_store_cert_path,
    )?;

    let app_store_key_path = cert_dir.join("app-store-key.json");
    unified.write_json_file(app_store_key_path)?;

    println!("Success!");
    println!("You can now sign your app using these three files:");
    println!("  - private-key.pem");
    println!("  - app-store-key.pem");
    println!("  - {}", cert_file.file_name().unwrap().to_string_lossy());

    Ok(())
}
