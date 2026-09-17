#!/usr/bin/env python3
"""TB variant helper.

Vypise presne varianty endgame tabuliek a vie ich aj nechat vygenerovat
cez externy tool. Pre kazdy variant ukazuje canonical Syzygy nazov
aj compact alias (napr. KPPPvK -> kpppK).

Ziadany rezim je typicky:
  1. preview variantov
  2. generovanie cez externy builder
  3. triedenie podla finalnej velkosti suboru

Priklad preview:
  python3 utils/rtbz_variants.py --max-pieces 5 --show both

Priklad generovania:
  python3 utils/rtbz_variants.py \
      --max-pieces 5 \
      --show both \
      --sided single \
      --generator 'tbgen --variant {canonical} --out {output}' \
      --output-dir /tmp/rtbz
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
from collections import Counter
from dataclasses import dataclass
from itertools import combinations_with_replacement
from pathlib import Path


PIECE_ORDER = ["Q", "R", "B", "N", "P"]
PIECE_ALIAS_ORDER = ["q", "r", "b", "n", "p"]
PIECE_WEIGHT = {"Q": 5, "R": 4, "B": 3, "N": 2, "P": 1}


@dataclass(frozen=True)
class Variant:
    canonical: str
    alias: str
    total_pieces: int
    white_pieces: tuple[str, ...]
    black_pieces: tuple[str, ...]


def _sort_pieces(pieces: list[str]) -> list[str]:
    return sorted(pieces, key=lambda piece: (-PIECE_WEIGHT[piece], piece))


def canonical_name(white_pieces: list[str], black_pieces: list[str]) -> str:
    left = "".join(_sort_pieces(white_pieces))
    right = "".join(_sort_pieces(black_pieces))
    return f"K{left}v{right}K"


def alias_name(white_pieces: list[str], black_pieces: list[str]) -> str:
    pieces = [piece.lower() for piece in _sort_pieces(white_pieces)]
    pieces.extend(piece.lower() for piece in _sort_pieces(black_pieces))
    return "k" + "".join(pieces) + "K"


def generate_single_side_variants(max_pieces: int) -> list[Variant]:
    variants: list[Variant] = []
    max_non_king = max(0, max_pieces - 2)
    for count in range(0, max_non_king + 1):
        for pieces in combinations_with_replacement(PIECE_ORDER, count):
            white_pieces = list(pieces)
            black_pieces: list[str] = []
            variants.append(
                Variant(
                    canonical=canonical_name(white_pieces, black_pieces),
                    alias=alias_name(white_pieces, black_pieces),
                    total_pieces=count + 2,
                    white_pieces=tuple(_sort_pieces(white_pieces)),
                    black_pieces=tuple(),
                )
            )
    return variants


def generate_all_side_variants(max_pieces: int) -> list[Variant]:
    variants: dict[str, Variant] = {}
    max_non_king = max(0, max_pieces - 2)
    for count in range(0, max_non_king + 1):
        for pieces in combinations_with_replacement(PIECE_ORDER, count):
            if count == 0:
                white_black_assignments = [([], [])]
            else:
                white_black_assignments = []
                for mask in range(1 << count):
                    white_pieces: list[str] = []
                    black_pieces: list[str] = []
                    for idx, piece in enumerate(pieces):
                        if mask & (1 << idx):
                            white_pieces.append(piece)
                        else:
                            black_pieces.append(piece)
                    white_black_assignments.append((white_pieces, black_pieces))

            for white_pieces, black_pieces in white_black_assignments:
                canonical = canonical_name(white_pieces, black_pieces)
                variants[canonical] = Variant(
                    canonical=canonical,
                    alias=alias_name(white_pieces, black_pieces),
                    total_pieces=count + 2,
                    white_pieces=tuple(_sort_pieces(white_pieces)),
                    black_pieces=tuple(_sort_pieces(black_pieces)),
                )
    return sorted(variants.values(), key=lambda item: (item.total_pieces, item.canonical))


def load_variants_file(path: Path) -> list[Variant]:
    with path.open("r", encoding="utf-8") as handle:
        data = json.load(handle)
    variants: list[Variant] = []
    for item in data:
        canonical = str(item["canonical"])
        alias = str(item.get("alias", canonical.lower()))
        total_pieces = int(item.get("total_pieces", canonical.count("K") + canonical.lower().count("p") + canonical.lower().count("n") + canonical.lower().count("b") + canonical.lower().count("r") + canonical.lower().count("q")))
        variants.append(
            Variant(
                canonical=canonical,
                alias=alias,
                total_pieces=total_pieces,
                white_pieces=tuple(),
                black_pieces=tuple(),
            )
        )
    return variants


def run_generator(template: str, output_path: Path, canonical: str, alias: str) -> None:
    cmd = template.format(output=str(output_path), canonical=canonical, alias=alias, variant=canonical)
    subprocess.run(cmd, shell=True, check=True)


def size_of(path: Path) -> int:
    return path.stat().st_size if path.exists() else -1


def print_variants(variants: list[Variant], show: str) -> None:
    for idx, variant in enumerate(variants, 1):
        if show == "canonical":
            label = variant.canonical
        elif show == "alias":
            label = variant.alias
        else:
            label = f"{variant.canonical} | {variant.alias}"
        print(f"{idx:03d}. {variant.total_pieces:>2} pieces  {label}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Vypise a/alebo vygeneruje TB varianty a zoradi ich podla vyslednej velkosti.")
    parser.add_argument("--max-pieces", type=int, default=5, help="Maximalny pocet figurok v TB variante vratane oboch kralov (default: 5)")
    parser.add_argument("--sided", choices=("single", "all"), default="single", help="single = jedna strana s materialom, all = vsetky rozdelenia materialu medzi strany")
    parser.add_argument("--show", choices=("canonical", "alias", "both"), default="both", help="Co vypisat pri preview")
    parser.add_argument("--generator", help="Command template s {output}, {canonical}, {alias}, {variant}")
    parser.add_argument("--output-dir", help="Adresar pre vygenerovane subory")
    parser.add_argument("--best-output", help="Volitelna kopia najlepsieho suboru")
    parser.add_argument("--report", help="Volitelny JSON report")
    parser.add_argument("--variants", help="Volitelny JSON subor s vlastnymi variantami")
    parser.add_argument("--manifest", help="Zapise manifest variantov (aj bez --generator)")
    args = parser.parse_args()

    if args.variants:
        variants = load_variants_file(Path(args.variants))
    elif args.sided == "all":
        variants = generate_all_side_variants(args.max_pieces)
    else:
        variants = generate_single_side_variants(args.max_pieces)

    print_variants(variants, args.show)

    if args.manifest:
        manifest_payload = [
            {
                "canonical": variant.canonical,
                "alias": variant.alias,
                "total_pieces": variant.total_pieces,
                "white_pieces": list(variant.white_pieces),
                "black_pieces": list(variant.black_pieces),
            }
            for variant in variants
        ]
        with open(args.manifest, "w", encoding="utf-8") as handle:
            json.dump(manifest_payload, handle, indent=2, ensure_ascii=False)
        print(f"Manifest ulozeny do: {args.manifest}")

    if not args.generator:
        return 0
    if not args.output_dir:
        raise SystemExit("--output-dir je povinne pri --generator")

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    results = []
    for variant in variants:
        output_path = output_dir / f"{variant.canonical}.rtbz"
        run_generator(args.generator, output_path, variant.canonical, variant.alias)
        results.append(
            {
                "canonical": variant.canonical,
                "alias": variant.alias,
                "total_pieces": variant.total_pieces,
                "output": str(output_path),
                "size": size_of(output_path),
            }
        )

    results.sort(key=lambda item: (item["size"], item["canonical"]))

    print()
    print("Varianty zoradene podla finalnej velkosti:")
    for idx, item in enumerate(results, 1):
        print(f"{idx:03d}. {item['size']:>12} B  {item['canonical']:<16} {item['alias']:<16} {item['output']}")

    if args.best_output and results:
        shutil.copy2(results[0]["output"], args.best_output)
        print(f"Najmensi subor skopirovany do: {args.best_output}")

    if args.report:
        with open(args.report, "w", encoding="utf-8") as handle:
            json.dump(results, handle, indent=2, ensure_ascii=False)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())