package storage

import (
	"archive/tar"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"math"
	"os"
	"path"

	digest "github.com/opencontainers/go-digest"
)

// TarGZ packs src (file or directory) into dst (.tar.gz format) file.
func TarGZ(dst, src string) (err error) {
	// clean path
	src = path.Clean(src)

	// get file or directory info
	fileInfo, err := os.Stat(src)
	if err != nil {
		return fmt.Errorf("failed to get info for [%v]: [%v]", src, err)
	}

	// create destination file
	file, err := os.Create(dst)
	if err != nil {
		return fmt.Errorf("failed to create destination file [%v]: [%v]", dst, err)
	}

	// perform packing
	gzipWriter := gzip.NewWriter(file)
	tarWriter := tar.NewWriter(gzipWriter)
	defer func() {
		// check close success; if close fails, the .tar.gz file may be incomplete
		if twErr := tarWriter.Close(); twErr != nil {
			err = twErr
		}
		if gwErr := gzipWriter.Close(); gwErr != nil {
			err = gwErr
		}
		if fwErr := file.Close(); fwErr != nil {
			err = fwErr
		}
	}()

	// get the base path and relative name of the source
	srcBase, srcRelative := path.Split(src)

	// start packing
	if fileInfo.IsDir() {
		return tarDir(srcBase, srcRelative, tarWriter, fileInfo)
	}
	return tarFile(srcBase, srcRelative, tarWriter, fileInfo)
}

// tarDir writes the srcRelative subdirectory under srcBase into tarWriter.
func tarDir(srcBase, srcRelative string, tarWriter *tar.Writer, fileInfo os.FileInfo) (err error) {
	// get full path
	dirPath := path.Join(srcBase, srcRelative)

	// get file and subdirectory list
	entries, err := os.ReadDir(dirPath)
	if err != nil {
		return fmt.Errorf("failed to read directory [%v]: [%v]", dirPath, err.Error())
	}

	// start traversal
	for i, entry := range entries {
		entryInfo, err := entry.Info()
		if err != nil {
			return fmt.Errorf("failed to get entry [%v] info in directory [%v]: [%v]", i, dirPath, err.Error())
		}
		filename := path.Join(srcRelative, entryInfo.Name())
		if entryInfo.IsDir() {
			tarDir(srcBase, filename, tarWriter, entryInfo)
		} else {
			tarFile(srcBase, filename, tarWriter, entryInfo)
		}
	}

	// write directory info
	if len(srcRelative) > 0 {
		header, err := tar.FileInfoHeader(fileInfo, "")
		if err != nil {
			return fmt.Errorf("failed to create tar header for directory [%v]: [%v]", dirPath, err.Error())
		}
		header.Name = srcRelative
		if err = tarWriter.WriteHeader(header); err != nil {
			return fmt.Errorf("failed to write tar header for directory [%v]: [%v]", dirPath, err.Error())
		}
	}

	return nil
}

// tarFile writes the srcRelative file under srcBase into tarWriter.
func tarFile(srcBase, srcRelative string, tarWriter *tar.Writer, fileInfo os.FileInfo) (err error) {
	// get full path
	filepath := path.Join(srcBase, srcRelative)

	// write file header
	header, err := tar.FileInfoHeader(fileInfo, "")
	if err != nil {
		return fmt.Errorf("failed to create tar header for file [%v]: [%v]", filepath, err.Error())
	}
	header.Name = srcRelative
	if err = tarWriter.WriteHeader(header); err != nil {
		return fmt.Errorf("failed to write tar header for file [%v]: [%v]", filepath, err.Error())
	}

	// write file data
	file, err := os.Open(filepath)
	if err != nil {
		return fmt.Errorf("failed to open file [%v]: [%v]", filepath, err.Error())
	}
	defer file.Close()
	if _, err = io.Copy(tarWriter, file); err != nil {
		return fmt.Errorf("failed to write file [%v] data: [%v]", filepath, err.Error())
	}

	return nil
}

// UnTarGZ extracts srcFile (.tar.gz format) to dstDir directory.
func UnTarGZ(dstDir, srcFile string) (err error) {
	// clean path
	dstDir = path.Clean(dstDir)

	// open compressed file
	file, err := os.Open(srcFile)
	if err != nil {
		return err
	}
	defer file.Close()

	// perform extraction
	gzipReader, err := gzip.NewReader(file)
	if err != nil {
		return err
	}
	defer gzipReader.Close()
	tarReader := tar.NewReader(gzipReader)
	for header, err := tarReader.Next(); err != io.EOF; header, err = tarReader.Next() {
		if err != nil {
			return err
		}

		// get file info
		fileInfo := header.FileInfo()

		// get absolute path
		dstFullPath := path.Join(dstDir, header.Name)

		if header.Typeflag == tar.TypeDir {
			// create directory
			err := os.MkdirAll(dstFullPath, fileInfo.Mode().Perm())
			if err != nil {
				return err
			}
			// set directory permission
			os.Chmod(dstFullPath, fileInfo.Mode().Perm())
			// set directory modification time
			os.Chtimes(dstFullPath, fileInfo.ModTime(), fileInfo.ModTime())
		} else if header.Typeflag == tar.TypeSymlink {
			// handle symlink
			err := os.Symlink(header.Linkname, dstFullPath)
			if err != nil {
				return fmt.Errorf("failed to create symlink [%v]: [%v]", dstFullPath, err.Error())
			}
			// set symlink permission
			os.Chmod(dstFullPath, fileInfo.Mode().Perm())
			// set symlink modification time
			os.Chtimes(dstFullPath, fileInfo.ModTime(), fileInfo.ModTime())
		} else {
			// create parent directory for file
			os.MkdirAll(path.Dir(dstFullPath), os.ModePerm)
			// write data from tarReader to file
			if err := unTarFile(dstFullPath, tarReader); err != nil {
				return err
			}
			// set file permission
			os.Chmod(dstFullPath, fileInfo.Mode().Perm())
			// set file modification time
			os.Chtimes(dstFullPath, fileInfo.ModTime(), fileInfo.ModTime())
		}
	}
	return nil
}

// unTarFile reads decompressed data from tarReader and writes to dstFile.
func unTarFile(dstFile string, tarReader *tar.Reader) error {
	file, err := os.Create(dstFile)
	if err != nil {
		return err
	}
	defer file.Close()

	_, err = io.Copy(file, tarReader)
	if err != nil {
		return err
	}
	return nil
}

func splitFileChunk(srcFile, destfpath string) error {
	var chunkSize int64 = 512 * 1024
	fileInfo, err := os.Stat(srcFile)
	if err != nil {
		fmt.Printf("spliterr : %v", err)
		return err
	}

	num := math.Ceil(float64(fileInfo.Size()) / float64(chunkSize))

	fi, err := os.OpenFile(srcFile, os.O_RDONLY, os.ModePerm)
	defer fi.Close()
	if err != nil {
		fmt.Printf("spliterr : %v", err)
		return err
	}

	b := make([]byte, chunkSize)
	var i int64 = 1
	for ; i <= int64(num); i++ {
		fi.Seek((i-1)*chunkSize, 0)
		if len(b) > int(fileInfo.Size()-(i-1)*chunkSize) {
			b = make([]byte, fileInfo.Size()-(i-1)*chunkSize)
		}
		fi.Read(b)
		ofile := fmt.Sprintf("%s/%d", destfpath, i)
		f, err := os.OpenFile(ofile, os.O_CREATE|os.O_WRONLY, os.ModePerm)
		if err != nil {
			fmt.Printf("spliterr : %v", err)
			return err
		}
		f.Write(b)
		f.Close()
	}
	return nil
}

// copyFile copies a file from src to dst, used when os.Rename fails across filesystems.
func copyFile(src, dst string) error {
	srcFile, err := os.Open(src)
	if err != nil {
		return err
	}
	defer srcFile.Close()

	dstFile, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer dstFile.Close()

	_, err = io.Copy(dstFile, srcFile)
	return err
}

// ========== File-as-Layer: File-level extraction ==========

// FileEntry represents a single file extracted from a tar.gz layer.
type FileEntry struct {
	TarPath    string        // original path inside the tar archive
	Digest     digest.Digest // sha256 digest of file content
	Content    []byte        // file content bytes
	Size       int64         // file size
	Mode       int64         // file permission mode
	TypeFlag   byte          // tar type flag (regular file, symlink, etc.)
	LinkTarget string        // symlink target (if TypeFlag == tar.TypeSymlink)
	IsDir      bool          // is this a directory entry
}

// ExtractFilesFromLayer opens a .tar.gz layer and extracts each file entry.
// It returns a slice of FileEntry with digests computed for regular files.
// Directories and symlinks are also captured for Merkle tree structure.
func ExtractFilesFromLayer(layerPath string) ([]FileEntry, error) {
	file, err := os.Open(layerPath)
	if err != nil {
		return nil, fmt.Errorf("cannot open layer file %s: %v", layerPath, err)
	}
	defer file.Close()

	gzReader, err := gzip.NewReader(file)
	if err != nil {
		return nil, fmt.Errorf("cannot create gzip reader for %s: %v", layerPath, err)
	}
	defer gzReader.Close()

	tarReader := tar.NewReader(gzReader)
	var entries []FileEntry

	for {
		header, err := tarReader.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("tar read error for %s: %v", layerPath, err)
		}

		entry := FileEntry{
			TarPath:  header.Name,
			Mode:     int64(header.Mode),
			TypeFlag: header.Typeflag,
		}

		switch header.Typeflag {
		case tar.TypeDir:
			entry.IsDir = true
			entry.Size = 0
			entries = append(entries, entry)

		case tar.TypeSymlink:
			entry.LinkTarget = header.Linkname
			entry.Size = 0
			// For symlinks, digest is computed from the link target string
			h := sha256.New()
			h.Write([]byte("symlink:" + header.Linkname))
			entry.Digest = digest.Digest("sha256:" + hex.EncodeToString(h.Sum(nil)))
			entries = append(entries, entry)

		case tar.TypeReg, tar.TypeRegA:
			// Regular file: read content and compute digest
			content, err := io.ReadAll(tarReader)
			if err != nil {
				return nil, fmt.Errorf("cannot read file %s from tar: %v", header.Name, err)
			}
			entry.Content = content
			entry.Size = int64(len(content))

			h := sha256.New()
			h.Write(content)
			entry.Digest = digest.Digest("sha256:" + hex.EncodeToString(h.Sum(nil)))
			entries = append(entries, entry)

		case tar.TypeLink:
			// Hard link
			entry.LinkTarget = header.Linkname
			entry.Size = 0
			h := sha256.New()
			h.Write([]byte("hardlink:" + header.Linkname))
			entry.Digest = digest.Digest("sha256:" + hex.EncodeToString(h.Sum(nil)))
			entries = append(entries, entry)

		default:
			// Whiteout files and other special types - still record them
			entry.Size = 0
			h := sha256.New()
			h.Write([]byte(fmt.Sprintf("special:%d:%s", header.Typeflag, header.Name)))
			entry.Digest = digest.Digest("sha256:" + hex.EncodeToString(h.Sum(nil)))
			entries = append(entries, entry)
		}
	}

	return entries, nil
}

// ComputeContentDigest computes a SHA256 digest for arbitrary byte content.
func ComputeContentDigest(content []byte) digest.Digest {
	h := sha256.New()
	h.Write(content)
	return digest.Digest("sha256:" + hex.EncodeToString(h.Sum(nil)))
}
