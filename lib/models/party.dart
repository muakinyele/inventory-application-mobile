/// Which of the two sales prices a customer is billed at.
enum PriceTier { retailer, distributor }

PriceTier priceTierFrom(String? raw) => PriceTier.values.firstWhere(
  (t) => t.name == raw,
  orElse: () => PriceTier.retailer,
);

extension PriceTierLabel on PriceTier {
  String get label => switch (this) {
    PriceTier.retailer => 'Retailer',
    PriceTier.distributor => 'Distributor',
  };
}

/// A business the stock is bought from.
class Supplier {
  const Supplier({
    required this.id,
    required this.name,
    this.contactName = '',
    this.phone = '',
    this.email = '',
    this.address = '',
    this.leadTimeDays = 0,
    this.paymentTerms = '',
    this.notes = '',
    this.archived = false,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final String contactName;
  final String phone;
  final String email;
  final String address;

  /// Working days between placing an order and receiving it. Drives how early
  /// a reorder has to be raised.
  final int leadTimeDays;

  final String paymentTerms;
  final String notes;

  /// Archived rather than deleted, so historical orders keep a readable name.
  final bool archived;

  final DateTime createdAt;
  final DateTime updatedAt;

  Supplier copyWith({
    String? name,
    String? contactName,
    String? phone,
    String? email,
    String? address,
    int? leadTimeDays,
    String? paymentTerms,
    String? notes,
    bool? archived,
    DateTime? updatedAt,
  }) {
    return Supplier(
      id: id,
      name: name ?? this.name,
      contactName: contactName ?? this.contactName,
      phone: phone ?? this.phone,
      email: email ?? this.email,
      address: address ?? this.address,
      leadTimeDays: leadTimeDays ?? this.leadTimeDays,
      paymentTerms: paymentTerms ?? this.paymentTerms,
      notes: notes ?? this.notes,
      archived: archived ?? this.archived,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'contactName': contactName,
    'phone': phone,
    'email': email,
    'address': address,
    'leadTimeDays': leadTimeDays,
    'paymentTerms': paymentTerms,
    'notes': notes,
    'archived': archived,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };
}

/// A business the stock is sold to.
class Customer {
  const Customer({
    required this.id,
    required this.name,
    this.contactName = '',
    this.phone = '',
    this.email = '',
    this.address = '',
    this.priceTier = PriceTier.retailer,
    this.notes = '',
    this.archived = false,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final String contactName;
  final String phone;
  final String email;
  final String address;

  /// Which price a sale to this customer defaults to.
  final PriceTier priceTier;

  final String notes;
  final bool archived;
  final DateTime createdAt;
  final DateTime updatedAt;

  Customer copyWith({
    String? name,
    String? contactName,
    String? phone,
    String? email,
    String? address,
    PriceTier? priceTier,
    String? notes,
    bool? archived,
    DateTime? updatedAt,
  }) {
    return Customer(
      id: id,
      name: name ?? this.name,
      contactName: contactName ?? this.contactName,
      phone: phone ?? this.phone,
      email: email ?? this.email,
      address: address ?? this.address,
      priceTier: priceTier ?? this.priceTier,
      notes: notes ?? this.notes,
      archived: archived ?? this.archived,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'contactName': contactName,
    'phone': phone,
    'email': email,
    'address': address,
    'priceTier': priceTier.name,
    'notes': notes,
    'archived': archived,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };
}
