# Copyright 2026 David Rolfe
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Writes a reproducible tar, or .tar.gz, of the given files: sorted, owned by
root, no gzip name or timestamp. Unchanged files therefore give a byte-identical
archive, which is how publish-data.sh tells that nothing needs uploading.

    python3 -I scripts/make_tar.py OUT.tar[.gz] BASEDIR MEMBER...
"""
import gzip
import os
import sys
import tarfile

out, base, members = sys.argv[1], sys.argv[2], sorted(sys.argv[3:])


def normalise(info):
    info.uid = info.gid = 0
    info.uname = info.gname = ""
    info.mode = 0o644
    info.mtime = int(info.mtime)
    return info


with open(out + ".part", "wb") as raw:
    f = gzip.GzipFile(filename="", fileobj=raw, mode="wb", mtime=0) if out.endswith(".gz") else raw
    # dereference: data/raw may link to another copy of the files (see data/README.md)
    with tarfile.open(fileobj=f, mode="w", format=tarfile.GNU_FORMAT, dereference=True) as tar:
        for m in members:
            tar.add(os.path.join(base, m), arcname=m, filter=normalise)
    if f is not raw:
        f.close()
os.replace(out + ".part", out)
