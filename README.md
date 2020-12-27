# s3up

s3up is a commandline tool that provides resumable multipart uploads
of files to Amazon S3.

## Usage

First, you create a multipart upload.  e.g., to create the object
`s3/obj` in the S3 bucket `my.s3.bucket` with the contents of
`/some/file`, you first create the multipart upload:

    s3up create --bucket my.s3.bucket /some/file s3/obj

(and any others you may wish to define) and then run all the
outstanding uploads with the upload command:

    s3up upload

## Commandline Reference

### create

The `create` command creates a multipart upload at S3 and records the
current state.

The `-s` option specifies the chunk size.  The default of 6 MB should
be enough in general, but you can go larger if you have a very large
file you need to upload.  A chunk size must be at least 5 MB to make
Amazon happy.

### upload

The `upload` command processes all outstanding uploads.

Files are processed in order of which have the least work to do (i.e.,
the ones that would finish soonest) and each individual file is
processed concurrently as limited by the `-u` option.
