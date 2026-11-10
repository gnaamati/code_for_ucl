#!/usr/bin/env python

import re
from typing import Dict

import requests


def get_json(ext: str) -> dict:
    """Fetches JSON from REST endpoint"""
    url = 'https://rest.ensembl.org/' + ext
    result = requests.get(url, headers={"Content-Type": "application/json"})
    if not result.ok:
        print("There seems to be a problem with the JSON response - please see below:\n")
        result.raise_for_status()
    return result.json()


def print_features(species: str, feature: Dict) -> None:
    """Prints features for the given species"""
    gene = feature['id']
    length = feature['end'] - feature['start'] + 1
    print(f'len={length}') 
    print("chrom", "start", "end", "strand", "length", sep = "\t")
    print(feature['seq_region_name'], feature['start'], feature['end'], feature['strand'], length, sep = "\t")

    # Get sequence
    ext2 = f'/sequence/id/{gene}?species={species};content-type=text/x-fasta'
    prot_data = get_json(ext2)
    print(f">{prot_data['id']}\n{prot_data['seq']}")


def get_overlapping_features(species: str, region: str):
    """Returns overlapping features for the given species and region"""
    print(f'species: {species}')
    print(f'region: {region}')

    # Get the genes via the API
    print("\n=====Genes===========\n")
    overlap_url = f'/overlap/region/{species}/{region}'
    ext = overlap_url + "?feature=gene;content-type=application/json"
    overlap_data = get_json(ext)
    for overlap_feat in overlap_data:
        if overlap_feat['biotype'] == 'protein_coding':
            print_features(species, overlap_feat)

    # Now LTR repeats
    print("\n=====LTR repeats===========\n")
    ext = overlap_url + "?feature=repeat;content-type=application/json"
    overlap_data = get_json(ext)
    print("description", "start", "end", sep = "\t")
    for overlap_feat in overlap_data:
        ltr_match = re.search('LTR', overlap_feat['description'])
        if ltr_match:
            print(overlap_feat['description'], overlap_feat['start'], overlap_feat['end'], sep = "\t")

    # Search for a specific variation source
    print("\n=====SNPs===========\n")
    source_variation = 'CerealsDB'
    ext = overlap_url + "?feature=variation;content-type=application/json"
    overlap_data = get_json(ext)
    print("id", "source", "consequence", sep = "\t")
    for overlap_feat in overlap_data:
        if overlap_feat['source'] == source_variation:
            print(overlap_feat['id'], overlap_feat['source'], overlap_feat['consequence_type'], sep = "\t")


if __name__ == '__main__':
    species = 'triticum_aestivum'
    region = '3D:379477845-379542988'
    get_overlapping_features(species, region)

