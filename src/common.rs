use anyhow::Result;
use jwalk::{ClientState, DirEntry};
use std::{
    fs::File,
    io::{Read, Seek, Write},
    path::PathBuf,
};
use zip::{write::SimpleFileOptions, ZipWriter};

pub fn zip_dir<T, C>(
    it: &mut dyn Iterator<Item = jwalk::Result<DirEntry<C>>>,
    prefix: Option<&PathBuf>,
    writer: T,
    method: zip::CompressionMethod,
) -> Result<()>
where
    T: Write + Seek,
    C: ClientState,
{
    let mut zip = ZipWriter::new(writer);
    let options = SimpleFileOptions::default()
        .compression_method(method)
        .unix_permissions(0o755);

    let mut buffer = Vec::new();
    for entry in it {
        let path = entry?.path();
        let name = match prefix {
            Some(p) => path.strip_prefix(p).unwrap(),
            None => path.as_path(),
        };

        // Write file or directory explicitly
        // Some unzip tools unzip files with directory paths correctly, some do not!
        if path.is_file() {
            // println!("adding file {path:?} as {name:?} ...");
            #[allow(deprecated)]
            zip.start_file_from_path(name, options)?;
            let mut f = File::open(path)?;

            f.read_to_end(&mut buffer)?;
            zip.write_all(&buffer)?;
            buffer.clear();
        } else if !name.as_os_str().is_empty() {
            // Only if not root! Avoids path spec / warning
            // and mapname conversion failed error on unzip
            // println!("adding dir {path:?} as {name:?} ...");
            #[allow(deprecated)]
            zip.add_directory_from_path(name, options)?;
        }
    }

    zip.finish()?;

    Ok(())
}

#[cfg(test)]
mod tests {
    use anyhow::Result;
    use jwalk::WalkDir;
    use std::fs::File;
    use zip::CompressionMethod;

    #[test]
    fn zip_dir() -> Result<()> {
        let mut files = WalkDir::new("src").into_iter();

        let file = File::create("src.zip").unwrap();

        super::zip_dir(&mut files, None, file, CompressionMethod::Deflated)?;

        let size = std::fs::metadata("src.zip")?.len();
        assert!(size > 0);

        std::fs::remove_file("src.zip")?;

        Ok(())
    }
}
