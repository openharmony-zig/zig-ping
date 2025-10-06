# @ohos-rs/zig-ping

A simple ping implement by zig.

> Note: This is an experiential project, if you want a stable version, please use `@ohos-rs/ping`.

## Usage

```ts
import { ping } from "@ohos-rs/zig-ping";

const handlePing = async () => {
  const ret = await ping("www.baidu.com");
  console.log(ret);
};
```

## Why we need it?

Previously, we had a fully functional ping tool built using `ohos-rs`.However, its release build size exceeded 900KB which is quite large for such a lightweight utility.

By re-implementing the same functionality in Zig, we successfully reduced the release build size to just 190KB—over four times smaller than the original version.

## License

[MIT](./LICENSE)
