# Resources and dependencies

Libere's Swift package declares no third-party Swift package dependencies.
Apple frameworks and SF Symbols are supplied by the operating system or SDK;
this repository does not redistribute those frameworks or the SF Symbols font.

Notebook execution uses an independently installed Python environment with
`jupyter_client` and `ipykernel`. Those projects are not bundled in this source
distribution and remain subject to their own licenses:

- Python: https://docs.python.org/3/license.html
- jupyter_client: https://github.com/jupyter/jupyter_client
- ipykernel: https://github.com/ipython/ipykernel
- traitlets: https://github.com/ipython/traitlets (used by the selected Jupyter environment)

The bundled scenario examples are generated from project-owned demonstration
content by `Scripts/generate-showcase.py` and `Scripts/MakeShowcasePDFs.swift`.
They are examples, not imported personal notebooks or third-party papers.
The supplied Libere artwork and example content follow the project LICENSE
unless a file contains a separate notice. See NOTICE for attribution.
