# SELinux media labels and the `/var/home` equivalency trap

A Jellyfin container that suddenly refuses to serve files it read yesterday, an `emryk-media-restorecon` unit that appears to run fine, and a media library whose every file carries `system_u:object_r:default_t:s0`. The audit log pointed at SELinux; the surprise was *why* — and it was not the label you thought was missing.

## Symptom

Jellyfin refuses playback of a media file that was copied into the library:

- Jellyfin log: `System.UnauthorizedAccessException: Access to the path '/data/media/...' is denied.`
- Audit log (`journalctl | grep AVC`):
  ```
  avc:  denied  { read } for ... comm="ffmpeg" \
      scontext=system_u:system_r:container_t:s0:c123,c456 \
      tcontext=system_u:object_r:default_t:s0 tclass=file permissive=0
  ```
- The whole tree checks out at the filesystem level: mode `rw-r--r--`, correct owner, `ffprobe` reads the file fine. Only the confined container (`container_t`) is blocked.

## What everything *should* have been

The media tree is labeled once, persistently, by a `semanage fcontext` rule, and the Jellyfin container has its MCS level pinned to match:

```bash
semanage fcontext -a -t container_file_t -r s0:c123,c456 "/home/alice/media(/.*)?"
```

and in `~/containers/jellyfin/docker-compose.yml`:

```yaml
security_opt:
  - label=level:s0:c123,c456
```

The compose file deliberately uses **no** `:Z` on the media volumes — the label is owned by the fcontext rule, not by whichever container started last. The `emryk-media-restorecon.service` user unit exists to re-apply that rule (`restorecon -RFv /var/home/alice/media`) on every import via a `.path` watch and a `.timer`.

This is the correct design. It stopped working anyway.

## Root cause: a rule stored under the wrong path prefix

`restorecon`/`setfiles` resolves labels against the file-context database *after* applying equivalency substitutions. Fedora ships an equivalency rule in `file_contexts.subs_dist`:

```
/var/home   /home
```

so a path like `/var/home/alice/media/...` is looked up in the database as `/home/alice/media/...`.

The fcontext rule had been recorded under the **non-canonical** prefix (`file_contexts.local`):

```
/var/home/alice/media(/.*)?    system_u:object_r:container_file_t:s0:c123,c456
```

After the equivalency translation, no rule matches the tree, so `restorecon -F` falls back to the policy default type — `default_t` — and dutifully "repaired" every file it visited. Because the `emryk-media-restorecon` unit runs with `-F` (mandatory, since the MCS level is precisely what gets corrupted by imports), each triggered pass silently relabeled the *entire* library from the correct `container_file_t:s0:c123,c456` to the unreadable `default_t:s0`. The audit trail shows it going wrong in one direction only:

```
Aug 22 09:26  restored container_file_t:s0:c789,c1011  →  container_file_t:s0:c123,c456   (correct)
Aug 24 10:49  destroyed container_file_t:s0:c123,c456  →  default_t:s0                      (bad)
Aug 24 20:40  destroyed container_file_t:s0            →  default_t:s0                      (bad)
```

`semanage fcontext -a` on the `/var/home` form correctly refuses the stale path — the error message is the diagnosis in one line:

```
ValueError: File spec /var/home/alice/media(/.*)? conflicts with equivalency
rule '/var/home /home'; Try adding '/home/alice/media(/.*)?' instead
```

## 404s to rule out along the way

- **Permissions/ownership** — fine; this was never a POSIX ACL problem.
- **The file itself** — fine; `ffprobe` reads the full stream.
- **A *missing* fcontext rule** — the rule was present all along; it was just queryable under a path that the match code never uses.
- **`emryk-media-restorecon.service` broken** — the unit worked exactly as written; the policy it was asked to re-apply was the wrong one.

## Fix

Record the rule under the canonical prefix and re-apply it:

```bash
sudo semanage fcontext -d "/var/home/alice/media(/.*)?"
sudo semanage fcontext -a -t container_file_t -r s0:c123,c456 "/home/alice/media(/.*)?"
sudo restorecon -RFv /var/home/alice/media
```

Verify every file now carries the pinned label:

```bash
ls -Z /var/home/alice/media/
# system_u:object_r:container_file_t:s0:c123,c456  on every entry
```

The `emryk-media-restorecon` unit needs no changes — with the rule at the canonical path, its passes now re-apply the correct label, exactly as designed. (The `.path` watcher may self-retrigger once after the relabel, as its comment documents.)

## Lesson

On any system where `/var/home` is equivalent to `/home`, fcontext specs must be added in the **canonical** form. The non-canonical form is accepted by the store but silently unreachable by `restorecon`, turning a safety net into an agent of label destruction. When a relabel pass starts producing `default_t`, check the equivalency tables first:

```bash
cat /etc/selinux/targeted/contexts/files/file_contexts.subs_dist
sudo semanage fcontext -l | grep -i media
```
