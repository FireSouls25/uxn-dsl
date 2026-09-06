# Uxn5

An emulator for the [Uxn stack-machine](https://wiki.xxiivv.com/site/uxn.html), written in Javascript. Check out a live demo at [rabbits.srht.site/uxn5](https://rabbits.srht.site/uxn5/)

## Usage

Include the uxn core in your `<head>` tag:

```html
<script src="src/uxn.js"></script>
```

Include the boot sequence in your website, and evaluate a program:

```html
<script type="text/javascript">
	const uxn = new Uxn()
	uxn.load(program).eval(0x0100)
</script>
```

## Including Rom

If you would like to include a rom directly in the emulator, modify [boot.js](https://git.sr.ht/~rabbits/uxn5/tree/main/item/src/boot.js) and add the rom as compressed base64 [ulz](https://wiki.xxiivv.com/site/ulz_format.html) encoded string, like:

```
const boot_ulz = "ASYUyuASyu_7ASHhua...";
```

## Need a hand?

The following resources are a good place to start:

* [XXIIVV — uxntal](https://wiki.xxiivv.com/site/uxntal.html)
* [XXIIVV — uxntal reference](https://wiki.xxiivv.com/site/uxntal_reference.html)
* [compudanzas — uxn tutorial](https://compudanzas.net/uxn_tutorial.html)

You can also find us in [`#uxn` on irc.esper.net](ircs://irc.esper.net:6697/#uxn).

## Contributing

Submit patches using [`git send-email`](https://git-send-email.io/) to the [~rabbits/public-inbox mailing list](https://lists.sr.ht/~rabbits/public-inbox).
