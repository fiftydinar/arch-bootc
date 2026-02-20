# Arch Linux Bootc Fork

Merge very needed stalled PRs until [upstream](https://github.com/bootcrew/arch-bootc) gets active again.

Merged PRs:
- https://github.com/bootcrew/arch-bootc/pull/20
- https://github.com/bootcrew/arch-bootc/pull/21
- https://github.com/bootcrew/arch-bootc/pull/22
- https://github.com/bootcrew/arch-bootc/pull/24

My changes on top of the merged PRs:

- Additionally, this PR below can be obsoleted, as I use a better and faster method of building `bootc` directly through AUR:
  https://github.com/bootcrew/arch-bootc/pull/23
- Replaced wrong `grep` expression syntax in `dracut` command call
