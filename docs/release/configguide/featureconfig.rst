.. This work is licensed under a
.. Creative Commons Attribution 4.0 International License.
.. http://creativecommons.org/licenses/by/4.0
.. (c) 2015-2017 AT&T Intellectual Property, Inc

==========================
OPNFV Models Configuration
==========================

.. contents::
   :depth: 3
   :local:

Hardware configuration
----------------------
There is currently no OPNFV installer support for the components used by the Models project.

Feature configuration
---------------------
The Models test scripts automatically install Models components. Instructions are included in the following scripts:

  * models/tests/vHello_Tacker.sh

Prerequisites to using vHello_Tacker:

  * OPFNV installed via JOID or Apex
  * a plain OpenStack installation such as DevStack
