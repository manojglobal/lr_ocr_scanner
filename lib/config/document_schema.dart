import 'package:flutter/foundation.dart';

/// Represents a single field definition within a document schema.
@immutable
class DocumentField {
  /// Unique key identifying the field in records (e.g. 'invoice_no').
  final String key;

  /// Human-readable label displayed in UI tables and Excel header (e.g. 'Invoice No').
  final String displayName;

  /// Alternative label strings that might appear on the document in OCR text.
  final List<String> aliases;

  /// Optional regular expression pattern to validate or extract token (e.g. date, amount).
  final RegExp? pattern;

  /// Whether this field is considered mandatory for complete extraction status.
  final bool isRequired;

  const DocumentField({
    required this.key,
    required this.displayName,
    this.aliases = const [],
    this.pattern,
    this.isRequired = false,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DocumentField &&
          runtimeType == other.runtimeType &&
          key == other.key;

  @override
  int get hashCode => key.hashCode;
}

/// Represents a configurable schema for a specific document format.
@immutable
class DocumentSchema {
  final String id;
  final String name;
  final String description;
  final List<DocumentField> fields;

  const DocumentSchema({
    required this.id,
    required this.name,
    required this.description,
    required this.fields,
  });

  /// Standard Invoice / Bill Schema (Default)
  static const DocumentSchema invoice = DocumentSchema(
    id: 'invoice',
    name: 'Standard Invoice / Bill',
    description: 'Extracts invoice number, date, vendor, customer, amount, tax, and payment info.',
    fields: [
      DocumentField(
        key: 'invoice_no',
        displayName: 'Invoice No',
        aliases: [
          'invoice no',
          'invoice #',
          'inv #',
          'inv no',
          'invoice number',
          'bill no',
          'bill #',
          'invoice id',
          'inv id',
        ],
        isRequired: true,
      ),
      DocumentField(
        key: 'date',
        displayName: 'Date',
        aliases: [
          'invoice date',
          'bill date',
          'issue date',
          'dated',
          'date',
          'trans date',
        ],
        isRequired: true,
      ),
      DocumentField(
        key: 'vendor',
        displayName: 'Vendor',
        aliases: [
          'vendor',
          'seller',
          'supplier',
          'merchant',
          'from',
          'company',
          'store',
        ],
        isRequired: false,
      ),
      DocumentField(
        key: 'customer',
        displayName: 'Customer Name',
        aliases: [
          'customer',
          'bill to',
          'billed to',
          'client',
          'buyer',
          'sold to',
          'ship to',
          'name',
        ],
        isRequired: false,
      ),
      DocumentField(
        key: 'total_amount',
        displayName: 'Total Amount',
        aliases: [
          'total amount',
          'grand total',
          'total due',
          'amount due',
          'net total',
          'total',
          'balance due',
        ],
        isRequired: true,
      ),
      DocumentField(
        key: 'tax',
        displayName: 'Tax',
        aliases: [
          'tax',
          'vat',
          'gst',
          'sales tax',
          'tax amount',
          'cgst',
          'sgst',
          'igst',
        ],
        isRequired: false,
      ),
      DocumentField(
        key: 'payment_method',
        displayName: 'Payment Method',
        aliases: [
          'payment method',
          'payment mode',
          'paid via',
          'payment type',
          'card',
          'cash',
          'terms',
        ],
        isRequired: false,
      ),
    ],
  );

  /// Retail Receipt Schema
  static const DocumentSchema receipt = DocumentSchema(
    id: 'receipt',
    name: 'Retail Receipt',
    description: 'Extracts store name, receipt date, receipt ID, subtotal, tax, and total amount.',
    fields: [
      DocumentField(
        key: 'store_name',
        displayName: 'Store Name',
        aliases: ['store', 'merchant', 'shop', 'vendor', 'supermarket'],
        isRequired: false,
      ),
      DocumentField(
        key: 'date',
        displayName: 'Date',
        aliases: ['date', 'time', 'trans date', 'datetime', 'dated'],
        isRequired: true,
      ),
      DocumentField(
        key: 'receipt_no',
        displayName: 'Receipt No',
        aliases: ['receipt #', 'rcpt #', 'receipt no', 'trans #', 'ticket #', 'order #'],
        isRequired: false,
      ),
      DocumentField(
        key: 'subtotal',
        displayName: 'Subtotal',
        aliases: ['subtotal', 'sub-total', 'sub total', 'items total'],
        isRequired: false,
      ),
      DocumentField(
        key: 'tax',
        displayName: 'Tax',
        aliases: ['tax', 'sales tax', 'vat', 'gst'],
        isRequired: false,
      ),
      DocumentField(
        key: 'total_amount',
        displayName: 'Total Amount',
        aliases: ['total', 'amount', 'balance', 'grand total', 'net amount'],
        isRequired: true,
      ),
    ],
  );

  /// Standard 38-Column Logistics GR Stock Import (ImportGRStockExcelFormat.xlsx)
  static const DocumentSchema grStock = DocumentSchema(
    id: 'gr_stock_38',
    name: 'GR Stock Format (38 Cols)',
    description: 'Matches ImportGRStockExcelFormat.xlsx with 38 ERP logistics columns.',
    fields: [
      DocumentField(key: 'stockdt', displayName: 'stockdt', aliases: ['stockdt', 'stock date', 'date']),
      DocumentField(key: 'branchrefcode', displayName: 'branchrefcode', aliases: ['branch', 'branch code']),
      DocumentField(key: 'grno', displayName: 'grno', aliases: ['grno', 'gr number', 'bilty no', 'lr no']),
      DocumentField(key: 'grdt', displayName: 'grdt', aliases: ['grdt', 'gr date', 'bilty date', 'date']),
      DocumentField(key: 'grtype', displayName: 'grtype', aliases: ['grtype', 'payment type']),
      DocumentField(key: 'orgrefcode', displayName: 'orgrefcode', aliases: ['from', 'origin', 'from station']),
      DocumentField(key: 'destrefcode', displayName: 'destrefcode', aliases: ['to', 'destination', 'to station']),
      DocumentField(key: 'cngr', displayName: 'cngr', aliases: ['cngr', 'consignor', 'sender', 'shipper']),
      DocumentField(key: 'cnge', displayName: 'cnge', aliases: ['cnge', 'consignee', 'receiver']),
      DocumentField(key: 'cngrgstno', displayName: 'cngrgstno', aliases: ['cngrgstno', 'consignor gst']),
      DocumentField(key: 'cngegstno', displayName: 'cngegstno', aliases: ['cngegstno', 'consignee gst']),
      DocumentField(key: 'productcode', displayName: 'productcode', aliases: ['productcode']),
      DocumentField(key: 'packing', displayName: 'packing', aliases: ['packing', 'packaging']),
      DocumentField(key: 'pmark', displayName: 'pmark', aliases: ['pmark', 'private mark']),
      DocumentField(key: 'goods', displayName: 'goods', aliases: ['goods', 'commodity', 'material']),
      DocumentField(key: 'freight', displayName: 'freight', aliases: ['freight', 'freight  *', 'freight amount', 'basic freight', 'total freight', 'freight charge', 'total_freight', 'basic_freight']),
      DocumentField(key: 'oamount', displayName: 'oamount', aliases: ['oamount', 'total invoice amount', 'gross invoice value', 'grand total', 'total invoice value', 'valgoods', 'value of goods', 'invoice value', 'declared value', 'other amount', 'hamali', 'other charges', 'loading charges', 'unloading charges', 'aoc', 'labour', 'st charge', 'statistical charge', 'misc']),
      DocumentField(key: 'cgst', displayName: 'cgst', aliases: ['cgst', 'cgst amount', 'central gst']),
      DocumentField(key: 'sgst', displayName: 'sgst', aliases: ['sgst', 'sgst amount', 'state gst']),
      DocumentField(key: 'igst', displayName: 'igst', aliases: ['igst', 'igst amount', 'integrated gst']),
      DocumentField(key: 'received', displayName: 'received', aliases: ['received', 'amount received', 'received amount', 'advance received', 'rcvd']),
      DocumentField(key: 'advance', displayName: 'advance', aliases: ['advance', 'advance amount', 'driver advance', 'adv']),
      DocumentField(key: 'collectionstncode', displayName: 'collectionstncode', aliases: ['collectionstncode', 'collection station', 'collection station code', 'collection stn code', 'coll stn', 'orgrefcode', 'from station', 'origin station', 'dispatch station']),
      DocumentField(key: 'ftl', displayName: 'ftl', aliases: ['ftl', 'ftl flag', 'full truck load', 'load type', 'vehicle load type']),
      DocumentField(key: 'bookedpckgs', displayName: 'bookedpckgs', aliases: ['bookedpckgs', 'packages', 'pkgs', 'quantity']),
      DocumentField(key: 'bookedaweight', displayName: 'bookedaweight', aliases: ['bookedaweight', 'actual weight', 'weight']),
      DocumentField(key: 'bookedcweight', displayName: 'bookedcweight', aliases: ['bookedcweight', 'charged weight']),
      DocumentField(key: 'custrefcode', displayName: 'custrefcode', aliases: ['custrefcode', 'customer ref code', 'customer code', 'cust code', 'party code', 'account code', 'customer ref']),
      DocumentField(key: 'staxpaidby', displayName: 'staxpaidby', aliases: ['staxpaidby', 'service tax paid by', 'stax paid by', 'gst paid by', 'tax paid by']),
      DocumentField(key: 'dlvtype', displayName: 'dlvtype', aliases: ['dlvtype', 'delivery type', 'dlv type', 'delivery mode']),
      DocumentField(key: 'stockpckgs', displayName: 'stockpckgs', aliases: ['stockpckgs', 'stockpkgs', 'stock packages', 'stock qty', 'stock quantity']),
      DocumentField(key: 'stockaweight', displayName: 'stockaweight', aliases: ['stockaweight', 'stock actual weight', 'stock act wt', 'stock weight']),
      DocumentField(key: 'stockcweight', displayName: 'stockcweight', aliases: ['stockcweight', 'stock charged weight', 'stock chg wt']),
      DocumentField(key: 'ewaybillno', displayName: 'ewaybillno', aliases: ['ewaybillno', 'eway bill', 'ewb']),
      DocumentField(key: 'invoiceno', displayName: 'invoiceno', aliases: ['invoiceno', 'invoice no', 'bill no']),
      DocumentField(key: 'invoiedt', displayName: 'invoiedt', aliases: ['invoiedt', 'invoice date']),
      DocumentField(key: 'valgoods', displayName: 'valgoods', aliases: ['valgoods', 'declared value', 'goods value']),
      DocumentField(key: 'viaborder', displayName: 'viaborder', aliases: ['viaborder']),
    ],
  );

  /// Extended 49-Column Logistics GR BNF Import (BNF file Modify.xlsx)
  static const DocumentSchema grBnf = DocumentSchema(
    id: 'gr_bnf_49',
    name: 'GR BNF Extended (49 Cols)',
    description: 'Matches GT Modify FIle with 49 columns including Vehicle, Driver, Counter, and Weight info.',
    fields: [
      DocumentField(key: 'branchrefcode', displayName: 'branchrefcode', aliases: ['branchrefcode', 'branch', 'counter', 'booking counter']),
      DocumentField(key: 'grno (*)', displayName: 'grno (*)', aliases: ['grno', 'gr number', 'bilty no', 'lr no', 'consignment note', 'c note', 'consignment note no', 'LR No *', 'LR No']),
      DocumentField(key: 'grdt *', displayName: 'grdt *', aliases: ['grdt', 'gr date', 'bilty date', 'lr date']),
      DocumentField(key: 'grtype', displayName: 'grtype', aliases: ['grtype', 'grtype(Don’t know)', 'payment type', 'pay type']),
      DocumentField(key: 'Customer Name *', displayName: 'Customer Name *', aliases: ['customer name', 'party name', 'customer']),
      DocumentField(key: 'Depatment Name', displayName: 'Depatment Name', aliases: ['department', 'depatment name', 'department name']),
      DocumentField(key: 'Counter name', displayName: 'Counter name', aliases: ['counter name', 'counter', 'booking counter', 'branchrefcode']),
      DocumentField(key: 'Transit Days', displayName: 'Transit Days', aliases: ['transit days', 'transit_days']),
      DocumentField(key: 'orgrefcode', displayName: 'orgrefcode', aliases: ['orgrefcode', 'from', 'origin']),
      DocumentField(key: 'destrefcode', displayName: 'destrefcode', aliases: ['destrefcode', 'to', 'destination']),
      DocumentField(key: 'cngr *', displayName: 'cngr *', aliases: ['cngr', 'consignor', 'sender']),
      DocumentField(key: 'cnge *', displayName: 'cnge *', aliases: ['cnge', 'consignee', 'receiver']),
      DocumentField(key: 'cngrgstno *', displayName: 'cngrgstno *', aliases: ['cngrgstno', 'consignor gst']),
      DocumentField(key: 'cngegstno *', displayName: 'cngegstno *', aliases: ['cngegstno', 'consignee gst']),
      DocumentField(key: 'productcode', displayName: 'productcode', aliases: ['productcode']),
      DocumentField(key: 'packing', displayName: 'packing', aliases: ['packing', 'packaging']),
      DocumentField(key: 'pmark', displayName: 'pmark', aliases: ['pmark', 'private mark']),
      DocumentField(key: 'goods', displayName: 'goods', aliases: ['goods', 'commodity']),
      DocumentField(key: 'Vehicle No *', displayName: 'Vehicle No *', aliases: ['vehicle no', 'truck no', 'lorry no']),
      DocumentField(key: 'Vehicle Type *', displayName: 'Vehicle Type *', aliases: ['vehicle type', 'truck type']),
      DocumentField(key: 'Driver Name *', displayName: 'Driver Name *', aliases: ['driver name', 'driver']),
      DocumentField(key: 'Mobile no   *', displayName: 'Mobile no   *', aliases: ['mobile no', 'driver mobile', 'phone']),
      DocumentField(key: 'Liscense No *', displayName: 'Liscense No *', aliases: ['license no', 'dl no']),
      DocumentField(key: 'Valid Up to *', displayName: 'Valid Up to *', aliases: ['valid up to', 'valid upto']),
      DocumentField(key: 'Loading Start date *', displayName: 'Loading Start date *', aliases: ['loading start date']),
      DocumentField(key: 'freight  *', displayName: 'freight  *', aliases: ['freight', 'freight  *', 'freight amount', 'basic freight', 'total freight', 'freight charge', 'total_freight', 'basic_freight']),
      DocumentField(key: 'oamount', displayName: 'oamount', aliases: ['oamount', 'total invoice amount', 'gross invoice value', 'grand total', 'total invoice value', 'valgoods', 'value of goods', 'invoice value', 'declared value', 'other amount', 'hamali', 'other charges', 'loading charges', 'unloading charges', 'aoc', 'labour', 'st charge', 'statistical charge', 'misc']),
      DocumentField(key: 'cgst', displayName: 'cgst', aliases: ['cgst', 'cgst amount', 'central gst']),
      DocumentField(key: 'sgst', displayName: 'sgst', aliases: ['sgst', 'sgst amount', 'state gst']),
      DocumentField(key: 'igst', displayName: 'igst', aliases: ['igst', 'igst amount', 'integrated gst']),
      DocumentField(key: 'received', displayName: 'received', aliases: ['received', 'amount received', 'received amount', 'advance received', 'rcvd']),
      DocumentField(key: 'advance', displayName: 'advance', aliases: ['advance', 'advance amount', 'driver advance', 'adv']),
      DocumentField(key: 'collectionstncode', displayName: 'collectionstncode', aliases: ['collectionstncode', 'collection station', 'collection station code', 'collection stn code', 'coll stn', 'orgrefcode', 'from station', 'origin station', 'dispatch station']),
      DocumentField(key: 'ftl', displayName: 'ftl', aliases: ['ftl', 'ftl flag', 'full truck load', 'load type', 'vehicle load type']),
      DocumentField(key: 'pckgs', displayName: 'pckgs', aliases: ['pckgs', 'bookedpckgs', 'packages', 'pkgs', 'stockpckgs', 'stockpkgs', 'quantity', 'qty']),
      DocumentField(key: 'Order Weight', displayName: 'Order Weight', aliases: ['Order Weight', 'order weight', 'order_weight']),
      DocumentField(key: 'aweight', displayName: 'aweight', aliases: ['aweight', 'bookedaweight', 'actual weight', 'actual wt', 'stockaweight', 'weight']),
      DocumentField(key: 'cweight', displayName: 'cweight', aliases: ['cweight', 'bookedcweight', 'charged weight', 'charged wt', 'stockcweight']),
      DocumentField(key: 'Contract wt', displayName: 'Contract wt', aliases: ['Contract wt', 'contract wt', 'contract weight']),
      DocumentField(key: 'Extra Mt', displayName: 'Extra Mt', aliases: ['Extra Mt', 'extra mt', 'extra_mt']),
      DocumentField(key: 'custrefcode', displayName: 'custrefcode', aliases: ['custrefcode', 'customer ref code', 'customer code', 'cust code', 'party code', 'account code', 'customer ref']),
      DocumentField(key: 'staxpaidby', displayName: 'staxpaidby', aliases: ['staxpaidby', 'service tax paid by', 'stax paid by', 'gst paid by', 'tax paid by']),
      DocumentField(key: 'dlvtype', displayName: 'dlvtype', aliases: ['dlvtype', 'delivery type', 'dlv type', 'delivery mode']),
      DocumentField(key: 'ewaybillno', displayName: 'ewaybillno', aliases: ['ewaybillno', 'eway bill']),
      DocumentField(key: 'Valid Upto', displayName: 'Valid Upto', aliases: ['valid upto']),
      DocumentField(key: 'invoiceno', displayName: 'invoiceno', aliases: ['invoiceno', 'invoice no']),
      DocumentField(key: 'invoiedt', displayName: 'invoiedt', aliases: ['invoiedt', 'invoice date']),
      DocumentField(key: 'valgoods', displayName: 'valgoods', aliases: ['valgoods', 'declared value']),
      DocumentField(key: 'viaborder', displayName: 'viaborder', aliases: ['viaborder']),
    ],
  );

  /// Universal Dynamic Structure Detector (Default - Any Image)
  static const DocumentSchema dynamic = DocumentSchema(
    id: 'dynamic',
    name: 'Auto-Detect Any Image',
    description: 'Automatically detects tables, columns, rows, and key-values from any image.',
    fields: [],
  );

  /// Generic Key-Value Schema
  static const DocumentSchema generic = DocumentSchema(
    id: 'generic',
    name: 'Generic Key-Value Form',
    description: 'Automatically detects any key: value pairs delimited in the text.',
    fields: [],
  );

  /// All available built-in schemas
  static const List<DocumentSchema> availableSchemas = [
    dynamic,
    grStock,
    grBnf,
    invoice,
    receipt,
    generic,
  ];

  /// Active default schema
  static const DocumentSchema active = dynamic;
}
